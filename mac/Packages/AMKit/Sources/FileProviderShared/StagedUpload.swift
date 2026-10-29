import Foundation

/// The file the extension staged for an upload, taken by the unsandboxed app without trusting
/// the path: it must be `<uploads>/<folder>/<name>`, and every step from `uploads` is opened
/// with `O_NOFOLLOW`, so no link (swapped in before or during the check) leads to another Mac
/// file. The opened descriptor is checked to be a regular file and copied (an APFS clone where
/// it can be) to `destination`, which the app then sends.
public enum StagedUpload {
    public struct Refused: Error, Equatable {}

    public static func copy(_ url: URL, stagedIn uploads: URL, to destination: URL) throws {
        let base = uploads.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard url.isFileURL, path.hasPrefix(base + "/") else { throw Refused() }
        let parts = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Refused() }

        let dirFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let top = open(base, dirFlags)
        guard top >= 0 else { throw Refused() }
        defer { close(top) }
        let folder = openat(top, parts[0], dirFlags)
        guard folder >= 0 else { throw Refused() }
        defer { close(folder) }
        // O_NONBLOCK: a FIFO or device opens at once and fails the regular-file check below.
        let fd = openat(folder, parts[1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Refused() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Refused() }
        // Blocking again for the copy (a regular file never blocks, but the stream copy expects it).
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)

        if fclonefileat(fd, AT_FDCWD, destination.path, 0) == 0 { return }
        try stream(fd, to: destination)
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
