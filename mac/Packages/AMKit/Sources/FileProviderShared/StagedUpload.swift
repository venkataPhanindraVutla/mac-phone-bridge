import Foundation

/// A file an extension staged in the App Group container, taken by the unsandboxed app without
/// trusting the path: it must lie a fixed number of steps below its staging folder (an upload is
/// `<uploads>/<folder>/<name>`, a share `<outbox>/<share>/<n>/<name>`), and every step from that
/// folder is opened with `O_NOFOLLOW`, so no link (swapped in before or during the check) leads
/// to another Mac file. The opened descriptor is checked to be a regular file and copied (an
/// APFS clone where it can be) to `destination`, which the app then sends. Whatever reaches the
/// app this way is bytes some process already wrote into the container.
public enum StagedUpload {
    public struct Refused: Error, Equatable {}

    /// The Finder upload the File Provider extension staged at `url`: `<uploads>/<folder>/<name>`.
    public static func copy(_ url: URL, stagedIn uploads: URL, to destination: URL) throws {
        let base = uploads.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard url.isFileURL, path.hasPrefix(base + "/") else { throw Refused() }
        let parts = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { throw Refused() }
        try copy(parts, under: uploads, to: destination)
    }

    /// The regular file `parts` (one name per step) below `root`, copied to `destination`.
    public static func copy(_ parts: [String], under root: URL, to destination: URL) throws {
        let fd = try openRegularFile(parts, under: root)
        defer { close(fd) }
        if fclonefileat(fd, AT_FDCWD, destination.path, 0) == 0 { return }
        try stream(fd, to: destination)
    }

    /// Whether `parts` below `root` is a regular file reached without a link.
    public static func isRegularFile(_ parts: [String], under root: URL) -> Bool {
        guard let fd = try? openRegularFile(parts, under: root) else { return false }
        close(fd)
        return true
    }

    /// One path step: not empty, not `.` or `..`, no `/` and no NUL.
    public static func isStep(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Opens `parts` below `root` step by step, never through a link; the last must be a regular
    /// file. Returns its descriptor, blocking, which the caller closes.
    static func openRegularFile(_ parts: [String], under root: URL) throws -> Int32 {
        guard let last = parts.last, parts.allSatisfy(isStep) else { throw Refused() }
        let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var dir = open(root.standardizedFileURL.path, dirFlags)
        guard dir >= 0 else { throw Refused() }
        for name in parts.dropLast() {
            let next = openat(dir, name, dirFlags)
            close(dir)
            guard next >= 0 else { throw Refused() }
            dir = next
        }
        defer { close(dir) }
        // O_NONBLOCK: a FIFO or device opens at once and fails the regular-file check below.
        let fd = openat(dir, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Refused() }
        var info = stat()
        // Blocking again for the copy (a regular file never blocks, but the stream copy expects it).
        let flags = fcntl(fd, F_GETFL)
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              flags != -1, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) != -1
        else {
            close(fd)
            throw Refused()
        }
        return fd
    }

    /// Copies what `fd` reads into a new file at `destination`.
    private static func stream(_ fd: Int32, to destination: URL) throws {
        let out = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var ok = false
        defer {
            close(out)
            if !ok { unlink(destination.path) }
        }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { break }
            guard n > 0 else { throw CocoaError(.fileReadUnknown) }
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { write(out, $0.baseAddress! + written, n - written) }
                guard w > 0 else { throw CocoaError(.fileWriteUnknown) }
                written += w
            }
        }
        ok = true
    }
}
