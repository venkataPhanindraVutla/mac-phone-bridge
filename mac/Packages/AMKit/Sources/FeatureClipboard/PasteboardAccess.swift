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
}
