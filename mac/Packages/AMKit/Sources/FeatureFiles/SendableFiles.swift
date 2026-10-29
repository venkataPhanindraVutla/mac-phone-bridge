import Foundation

/// Which picked or dropped URLs can be sent: files only. A folder, a package (an app, an
/// `.rtfd`: a folder Finder shows as one file) or a link to either is skipped, for now.
public enum SendableFiles {
    public static func split(_ urls: [URL]) -> (files: [URL], skipped: Int) {
        var files: [URL] = []
        var skipped = 0
        for url in urls {
            let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true || values?.isPackage == true {
                skipped += 1
            } else {
                files.append(url)
            }
        }
        return (files, skipped)
    }
}
