import Darwin
import Foundation
import os

public enum ShortcutRunResult: Equatable, Sendable {
    case ok
    /// The exit code; -1 when the tool couldn't be started.
    case failed(Int32)
    case timedOut
}

/// Lists and runs Shortcuts. Never called on the ordered queue: a shortcut can take seconds, or hang.
public protocol ShortcutRunner: Sendable {
    /// The names of the user's shortcuts; nil when the tool can't run.
    func list() async -> [String]?
    func run(_ name: String) async -> ShortcutRunResult
}

/// `/usr/bin/shortcuts list` and `run`, each killed after `timeout`.
///
/// The process gets no stdin; its stdout is read as it comes (and dropped for `run`), its stderr
/// goes nowhere. Logs carry exit codes and counts only, never shortcut names or output.
///
/// Foundation calls the termination and readability handlers on threads of its own. This type is
/// not main-actor isolated, so neither are the closures made here (Swift 6 traps a main-actor
/// closure that runs anywhere else).
public struct SystemShortcuts: ShortcutRunner {
    let tool: URL
    let timeout: Duration
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "focus")

    public init(tool: URL = URL(fileURLWithPath: "/usr/bin/shortcuts"), timeout: Duration = .seconds(10)) {
        self.tool = tool
        self.timeout = timeout
    }

    public func list() async -> [String]? {
        let (end, output) = await Self.execute(tool, ["list"], timeout: timeout)
        switch end {
        case .exited(0):
            let names = String(decoding: output, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.isEmpty }
            Self.log.info("shortcuts list exit 0 count \(names.count, privacy: .public)")
            return names
        case let .exited(code):
            Self.log.error("shortcuts list exit \(code, privacy: .public)")
            return nil
        case .timedOut:
            Self.log.error("shortcuts list timed out")
            return nil
        case .notStarted:
            Self.log.error("shortcuts list couldn't start")
            return nil
        }
    }

    public func run(_ name: String) async -> ShortcutRunResult {
        let (end, _) = await Self.execute(tool, ["run", name], timeout: timeout)
        switch end {
        case .exited(0):
            Self.log.info("shortcuts run exit 0")
            return .ok
        case let .exited(code):
            Self.log.error("shortcuts run exit \(code, privacy: .public)")
            return .failed(code)
        case .timedOut:
            Self.log.error("shortcuts run timed out")
            return .timedOut
        case .notStarted:
            Self.log.error("shortcuts run couldn't start")
            return .failed(-1)
        }
    }

    enum End: Equatable, Sendable {
        case exited(Int32), timedOut, notStarted
    }

    /// Runs the tool to its end: it exited and its stdout reached end of file, or `timeout` passed.
    /// Past the timeout it is terminated, then killed a second later if it is still there.
    static func execute(_ tool: URL, _ arguments: [String], timeout: Duration) async -> (End, Data) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let reading = pipe.fileHandleForReading
        let state = RunState()

        return await withCheckedContinuation { continuation in
            state.start(continuation, process: process) {
                reading.readabilityHandler = nil
            }
            reading.readabilityHandler = { handle in state.received(handle.availableData) }
            process.terminationHandler = { finished in state.exited(finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                state.notStarted()
                return
            }
            let pid = process.processIdentifier
            state.deadline = Task.detached {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, state.timeOut() else { return }
                kill(pid, SIGTERM)
                try? await Task.sleep(for: .seconds(1))
                if state.stillRunning { kill(pid, SIGKILL) }
            }
        }
    }
}

/// One run's progress, from Foundation's threads and the deadline task.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(SystemShortcuts.End, Data), Never>?
    private var cleanUp: (@Sendable () -> Void)?
    private var output = Data()
    private var status: Int32?
    private var endOfFile = false
    private var processGone = false
    private var _deadline: Task<Void, Never>?
    /// Held until it exits, so nothing depends on Foundation keeping a running process alive.
    private var process: Process?

    func start(_ continuation: CheckedContinuation<(SystemShortcuts.End, Data), Never>, process: Process,
               cleanUp: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.continuation = continuation
            self.process = process
            self.cleanUp = cleanUp
        }
    }

    var deadline: Task<Void, Never>? {
        get { lock.withLock { _deadline } }
        set {
            let finished = lock.withLock { () -> Bool in
                _deadline = newValue
                return continuation == nil
            }
            if finished { newValue?.cancel() }
        }
    }

    var stillRunning: Bool { lock.withLock { !processGone } }

    func received(_ data: Data) {
        let end: (SystemShortcuts.End, Data)? = lock.withLock {
            if data.isEmpty { endOfFile = true } else { output.append(data) }
            return ended()
        }
        finish(end)
    }

    func exited(_ code: Int32) {
        let end: (SystemShortcuts.End, Data)? = lock.withLock {
            processGone = true
            process = nil
            status = code
            return ended()
        }
        finish(end)
    }

    func notStarted() {
        let end: (SystemShortcuts.End, Data)? = lock.withLock {
            processGone = true
            process = nil
            return continuation == nil ? nil : (.notStarted, Data())
        }
        finish(end)
    }

    /// The timeout passed. True when the process must be stopped. One that has exited but whose
    /// output is still held open (by a child of its own) ends with its exit code.
    func timeOut() -> Bool {
        let (end, stop): ((SystemShortcuts.End, Data)?, Bool) = lock.withLock {
            guard continuation != nil else { return (nil, false) }
            if let status { return ((.exited(status), output), false) }
            return ((.timedOut, Data()), true)
        }
        finish(end)
        return stop
    }

    /// Must hold the lock.
    private func ended() -> (SystemShortcuts.End, Data)? {
        guard continuation != nil, let status, endOfFile else { return nil }
        return (.exited(status), output)
    }

    /// Resumes once; later calls find no continuation.
    private func finish(_ end: (SystemShortcuts.End, Data)?) {
        guard let end else { return }
        let taken = lock.withLock { () -> (CheckedContinuation<(SystemShortcuts.End, Data), Never>, (@Sendable () -> Void)?, Task<Void, Never>?)? in
            guard let c = continuation else { return nil }
            continuation = nil
            defer { cleanUp = nil }
            return (c, cleanUp, end.0 == .timedOut ? nil : _deadline)
        }
        guard let (continuation, cleanUp, deadline) = taken else { return }
        cleanUp?()
        deadline?.cancel()
        continuation.resume(returning: end)
    }
}
