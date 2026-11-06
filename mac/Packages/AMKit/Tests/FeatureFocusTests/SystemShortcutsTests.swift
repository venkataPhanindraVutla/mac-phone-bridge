import Foundation
import Testing
@testable import FeatureFocus

/// A shell script in a fresh temp directory, standing in for `/usr/bin/shortcuts`.
private func tool(_ body: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-shortcuts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("shortcuts")
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Test func listParsesNames() async throws {
    let url = try tool("""
    [ "$1" = list ] || exit 9
    printf 'Mac Phone Bridge Focus On\\nMac Phone Bridge Focus Off\\n\\nMorning Routine\\n'
    """)
    let names = await SystemShortcuts(tool: url).list()
    #expect(names == ["Mac Phone Bridge Focus On", "Mac Phone Bridge Focus Off", "Morning Routine"])
}

@Test func listOfNothingIsEmpty() async throws {
    let url = try tool("exit 0")
    #expect(await SystemShortcuts(tool: url).list() == [])
}

@Test func largeOutputIsDrained() async throws {
    // More than a pipe buffer holds: the tool would block if the output were not read as it comes.
    let url = try tool("i=0; while [ $i -lt 5000 ]; do echo \"Shortcut number $i with a long name\"; i=$((i+1)); done")
    let names = await SystemShortcuts(tool: url).list()
    #expect(names?.count == 5000)
    #expect(names?.last == "Shortcut number 4999 with a long name")
}

@Test func runPassesTheNameAndGetsNoInput() async throws {
    // No stdin: `read` sees end of file at once instead of waiting.
    let url = try tool("""
    [ "$1" = run ] && [ "$2" = "Mac Phone Bridge Focus On" ] || exit 9
    if read line; then exit 8; fi
    exit 0
    """)
    #expect(await SystemShortcuts(tool: url).run(FocusModel.onShortcut) == .ok)
}

@Test func nonZeroExitIsFailed() async throws {
    let url = try tool("echo partial; exit 3")
    let shortcuts = SystemShortcuts(tool: url)
    #expect(await shortcuts.run("Mac Phone Bridge Focus Off") == .failed(3))
    #expect(await shortcuts.list() == nil)
}

@Test func missingToolCannotRun() async {
    let shortcuts = SystemShortcuts(tool: URL(fileURLWithPath: "/nonexistent/shortcuts"))
    #expect(await shortcuts.list() == nil)
    #expect(await shortcuts.run("Mac Phone Bridge Focus On") == .failed(-1))
}

/// A tool that would run for a minute ends in `.timedOut` at the timeout, not at its own end. The
/// upper bound is half the tool's run, far from the timeout, so a slow runner cannot break it.
@Test func hangingShortcutTimesOutAfter10s() async throws {
    #expect(SystemShortcuts().timeout == .seconds(10))
    let url = try tool("exec sleep 60")
    let shortcuts = SystemShortcuts(tool: url, timeout: .milliseconds(300))
    let clock = ContinuousClock()
    let start = clock.now
    let result = await shortcuts.run("Mac Phone Bridge Focus On")
    #expect(result == .timedOut)
    #expect(clock.now - start >= .milliseconds(300))
    #expect(clock.now - start < .seconds(30))
    let listStart = clock.now
    #expect(await shortcuts.list() == nil)
    #expect(clock.now - listStart >= .milliseconds(300))
    #expect(clock.now - listStart < .seconds(30))
}

/// A tool that ignores SIGTERM: the run still ends at the timeout, while the tool is still there,
/// and does not wait for the SIGKILL that follows (`killAfter`, a minute here).
@Test func ignoredTerminateStillTimesOut() async throws {
    // The pid file is written once the trap is set. A shell that a loaded machine kept from
    // getting that far within the 2 s timeout ended at the SIGTERM instead, which proves nothing
    // about a tool that ignores it: such a run is tried again, at most three times.
    for attempt in 1...3 {
        let url = try tool("trap '' TERM; echo $$ > \"$0.pid\"; exec sleep 60")
        var shortcuts = SystemShortcuts(tool: url, timeout: .seconds(2))
        shortcuts.killAfter = .seconds(60)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await shortcuts.run("x") == .timedOut)
        #expect(clock.now - start >= .seconds(2))
        #expect(clock.now - start < .seconds(30))
        guard let text = try? String(contentsOf: url.appendingPathExtension("pid"), encoding: .utf8) else {
            if attempt < 3 { continue }
            Issue.record("the shell never set its trap within the timeout")
            return
        }
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0, "the result came while the tool still ran")
        kill(pid, SIGKILL)
        return
    }
}

/// Called from the main actor: the termination and readability handlers run on Foundation's own
/// threads, and none of them may be main-actor isolated (Swift 6 traps at entry).
@MainActor @Test func handlersRunOffTheMainActorWhenCalledFromIt() async throws {
    let url = try tool("echo one; echo two")
    let names = await SystemShortcuts(tool: url).list()
    #expect(names == ["one", "two"])
    let fail = try tool("exit 4")
    #expect(await SystemShortcuts(tool: fail).run("x") == .failed(4))
}

/// stdout closed long before the tool exits: end of file is read once, and the handler is not
/// called again and again while the process runs on.
@Test func earlyClosedStdoutIsReadOnce() async throws {
    let url = try tool("echo done; exec >&-; sleep 0.5; exit 0")
    let outcome = await SystemShortcuts.execute(url, ["list"], timeout: .seconds(5))
    #expect(outcome.result.0 == .exited(0))
    #expect(String(decoding: outcome.result.1, as: UTF8.self) == "done\n")
    #expect(outcome.reads <= 2)
}
