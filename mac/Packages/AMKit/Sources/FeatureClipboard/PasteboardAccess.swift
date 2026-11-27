import AppKit

/// The parts of a pasteboard the clipboard model uses, so tests can stand in for the system one.
@MainActor
public protocol PasteboardAccess: AnyObject {
    /// Moves on every time anyone writes the pasteboard.
    var changeCount: Int { get }
    /// The type identifiers of what is on the pasteboard now.
    var types: [String] { get }
    func readString() -> String?
    /// Replaces the contents with `s` as plain text, with no other types.
    func writeString(_ s: String)
    /// The image on the pasteboard as PNG bytes (PNG kept as is, TIFF or JPEG converted); nil when none.
    func readImagePNG() -> Data?
    /// Replaces the contents with the image in `data`; false when it is not an image.
    func writeImage(_ data: Data) -> Bool
}

/// `NSPasteboard.general`.
@MainActor
public final class SystemPasteboard: PasteboardAccess {
    private let board: NSPasteboard

    public init(board: NSPasteboard = .general) { self.board = board }

    public var changeCount: Int { board.changeCount }

    public var types: [String] { board.types?.map(\.rawValue) ?? [] }

    public func readString() -> String? { board.string(forType: .string) }

    public func writeString(_ s: String) {
        board.clearContents()
        board.setString(s, forType: .string)
    }

    public func readImagePNG() -> Data? {
        if let png = board.data(forType: .png) { return png }
        for type in [NSPasteboard.PasteboardType.tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = board.data(forType: type), let rep = NSBitmapImageRep(data: data) {
                return rep.representation(using: .png, properties: [:])
            }
        }
        return nil
    }

    public func writeImage(_ data: Data) -> Bool {
        guard let image = NSImage(data: data) else { return false }
        board.clearContents()
        return board.writeObjects([image])
    }
}
