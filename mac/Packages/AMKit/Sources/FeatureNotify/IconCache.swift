import CryptoKit
import Foundation
import os

/// App icons the phone sent (PNG), one file per package, kept on disk so notifications can carry them.
public final class IconCache {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// The cached icon's file, or nil when there is none.
    public func url(for package: String) -> URL? {
        let url = fileURL(for: package)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func store(_ png: Data, for package: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: fileURL(for: package), options: .atomic)
        } catch {
            // An icon is decoration; losing one is harmless and it is requested again next session.
            Logger(subsystem: "io.github.anmirror.mac", category: "notify")
                .error("icon cache write failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func fileURL(for package: String) -> URL {
        let hash = SHA256.hash(data: Data(package.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".png")
    }
}
