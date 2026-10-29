import FeatureFiles
import Foundation
import os
import UniformTypeIdentifiers

/// Drag-out of a file that is still on the phone: an item provider whose file is fetched only
/// when the drop lands (and the receiver asks for it). Each drag gets its own folder under
/// `folder`; a failed fetch leaves nothing there, a delivered file is removed a while after the
/// receiver has taken its copy, and the whole folder is swept at launch.
enum FilePromise {
    /// Where promised files are fetched to before the receiver takes them.
    static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("io.github.anmirror.mac/promises", isDirectory: true)
    /// How long a delivered file stays for the receiver to copy.
    static let keepDelivered: Duration = .seconds(120)
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "promise")

    /// `fetch` gets the file URL to write and returns where the file ended up; it runs in a task
    /// that is cancelled when the receiver gives up, so it should end its request then. The load
    /// handler calls its completion exactly once: with the file, with the fetch's failure, or
    /// with "cancelled" when the receiver gives up first (a file that still arrives is removed).
    static func provider(name: String, type: UTType,
                         fetch: @escaping @MainActor @Sendable (URL) async -> Result<URL, TransferFailure>) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let once = Once(completion)
            let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let file = dir.appendingPathComponent(FileNameSanitizer.sanitize(name))
            let work = Task { @MainActor in
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    once(nil, CocoaError(.fileWriteUnknown))
                    return
                }
                switch await fetch(file) {
                case let .success(url):
                    progress.completedUnitCount = 1
                    guard once(url, nil) else {
                        // The receiver gave up before the file came: nobody takes it.
                        remove(dir)
                        return
                    }
                    Task.detached(priority: .utility) {
                        try? await Task.sleep(for: keepDelivered)
                        remove(dir)
                    }
                case let .failure(failure):
                    log.info("fetch failed: \(String(describing: failure), privacy: .public)")
                    // The engine already removed its partial file; the folder goes too.
                    remove(dir)
                    once(nil, failure == .transfer(.cancelled) ? CocoaError(.userCancelled) : CocoaError(.fileReadUnknown))
                }
            }
            progress.cancellationHandler = {
                once(nil, CocoaError(.userCancelled))
                // On the main actor, where the fetch ends its request (`TransferEngine.cancelRequest`).
                Task { @MainActor in work.cancel() }
            }
            return progress
        }
        return provider
    }

    private static func remove(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Calls a file representation's completion at most once, from whichever path gets there first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private let completion: @Sendable (URL?, Bool, (any Error)?) -> Void

    init(_ completion: @escaping @Sendable (URL?, Bool, (any Error)?) -> Void) {
        self.completion = completion
    }

    /// Whether this call was the one that completed.
    @discardableResult
    func callAsFunction(_ url: URL?, _ error: (any Error)?) -> Bool {
        let first = lock.withLock {
            defer { called = true }
            return !called
        }
        if first { completion(url, false, error) }
        return first
    }
}
