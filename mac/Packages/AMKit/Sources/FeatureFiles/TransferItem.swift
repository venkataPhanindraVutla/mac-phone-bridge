import AMProtocol
import Foundation

/// One transfer as the UI shows it.
public struct TransferItem: Identifiable, Equatable, Sendable {
    public enum Direction: Sendable { case send, receive }

    public enum State: Equatable, Sendable {
        /// Waiting for an earlier transfer in the same direction to end.
        case queued
        /// Offered or accepted; no bytes yet.
        case waiting
        case active
        /// Received files carry where they were saved; sent files carry nil.
        case done(URL?)
        case failed(AMTransferError)
        case cancelled
    }

    public let id: String
    public let direction: Direction
    /// The sanitized file name.
    public let name: String
    public let size: UInt64
    /// Bytes moved so far.
    public var done: UInt64
    public let kind: AMTransferKind
    public var state: State
    /// A Mac send into a browse folder (it needs `browse.v1`), not to the phone's Downloads.
    public let targeted: Bool

    public init(id: String, direction: Direction, name: String, size: UInt64, done: UInt64 = 0,
                kind: AMTransferKind, state: State, targeted: Bool = false) {
        self.id = id
        self.direction = direction
        self.name = name
        self.size = size
        self.done = done
        self.kind = kind
        self.state = state
        self.targeted = targeted
    }

    /// Done, failed or cancelled.
    public var isFinal: Bool {
        switch state {
        case .queued, .waiting, .active: false
        case .done, .failed, .cancelled: true
        }
    }
}

/// The listed transfers in one direction that failed (or that the phone cancelled) since the
/// last transfer in that direction was queued.
public struct TransferFailureSummary: Equatable, Sendable {
    /// The newest of them.
    public let newest: TransferItem
    public let count: Int
    /// Whether all of them ended the same way, so one reason line fits them all.
    public let sameReason: Bool

    public init(newest: TransferItem, count: Int = 1, sameReason: Bool = true) {
        self.newest = newest
        self.count = count
        self.sameReason = sameReason
    }

    /// This summary with `item` failed too.
    func adding(_ item: TransferItem) -> TransferFailureSummary {
        TransferFailureSummary(newest: item, count: count + 1, sameReason: sameReason && newest.state == item.state)
    }
}

/// One menu line: the transfer under way in a direction, and how many more wait behind it.
public struct TransferMenuLine: Equatable, Sendable {
    public let item: TransferItem
    public let waiting: Int
}

/// What the menu shows of the transfer list (ruling R11, like the phone's R9): at most one line
/// per direction, sends first. The full list is the Phone window's. Phone screenshots arriving
/// on their own are not menu lines (R13); they stay in the list, and a failed one still counts.
public enum TransferMenu {
    public static func lines(_ transfers: [TransferItem]) -> [TransferMenuLine] {
        [TransferItem.Direction.send, .receive].compactMap { direction in
            let open = transfers.filter {
                $0.direction == direction && !$0.isFinal && !($0.direction == .receive && $0.kind == .screenshot)
            }
            guard let shown = open.first(where: { $0.state != .queued }) ?? open.first else { return nil }
            return TransferMenuLine(item: shown, waiting: open.count - 1)
        }
    }
}
