import FileProvider
import FileProviderShared
import UniformTypeIdentifiers

/// A phone root, folder or file as Finder sees it. Identifiers are `PhoneItemID`s; the domain's
/// root container lists the phone's browse roots. Browsing is read-only apart from adding files
/// to folders of a writable root.
final class PhoneItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion

    private init(id: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, name: String,
                 isDir: Bool, writable: Bool, size: UInt64?, modifiedMs: Int64?, mime: String) {
        itemIdentifier = id
        parentItemIdentifier = parent
        filename = name
        if isDir {
            contentType = .folder
            capabilities = writable
                ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
                : [.allowsReading, .allowsContentEnumerating]
        } else {
            let ext = (name as NSString).pathExtension
            contentType = (ext.isEmpty ? nil : UTType(filenameExtension: ext))
                ?? (mime.isEmpty ? nil : UTType(mimeType: mime)) ?? .data
            capabilities = [.allowsReading]
        }
        documentSize = isDir ? nil : size.map { NSNumber(value: $0) }
        contentModificationDate = modifiedMs.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000) : nil }
        // Size and time stand for the content; the name is metadata too.
        let content = Data("\(size ?? 0)/\(modifiedMs ?? 0)".utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: content, metadataVersion: content + Data(name.utf8))
    }

    /// The domain's root: the phone, listing its browse roots. Nothing can be added at this level.
    static func container(named name: String) -> PhoneItem {
        PhoneItem(id: .rootContainer, parent: .rootContainer, name: name, isDir: true, writable: false,
                  size: nil, modifiedMs: nil, mime: "")
    }

    static func root(_ root: RootDTO) -> PhoneItem {
        PhoneItem(id: NSFileProviderItemIdentifier(PhoneItemID.encode(rootID: root.id, path: "")),
                  parent: .rootContainer, name: root.name, isDir: true, writable: root.writable,
                  size: nil, modifiedMs: nil, mime: "")
    }

    /// `entry`, in the folder `folderPath` of root `rootID`.
    static func entry(_ entry: EntryDTO, rootID: String, folderPath: String, writable: Bool) -> PhoneItem {
        let path = folderPath.isEmpty ? entry.name : folderPath + "/" + entry.name
        return PhoneItem(id: NSFileProviderItemIdentifier(PhoneItemID.encode(rootID: rootID, path: path)),
                         parent: NSFileProviderItemIdentifier(PhoneItemID.encode(rootID: rootID, path: folderPath)),
                         name: entry.name, isDir: entry.isDir, writable: writable,
                         size: entry.size, modifiedMs: entry.modifiedMs, mime: entry.mime)
    }
}

/// A phone path's folder and name: `("a/b", "c")` for `"a/b/c"`, `("", "c")` for `"c"`.
func split(_ path: String) -> (folder: String, name: String) {
    guard let slash = path.lastIndex(of: "/") else { return ("", path) }
    return (String(path[..<slash]), String(path[path.index(after: slash)...]))
}
