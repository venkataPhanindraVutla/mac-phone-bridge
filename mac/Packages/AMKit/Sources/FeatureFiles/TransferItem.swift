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

    public init(id: String, direction: Direction, name: String, size: UInt64, done: UInt64 = 0,
                kind: AMTransferKind, state: State) {
        self.id = id
        self.direction = direction
        self.name = name
        self.size = size
        self.done = done
        self.kind = kind
        self.state = state
    }

    /// Done, failed or cancelled.
    public var isFinal: Bool {
        switch state {
        case .queued, .waiting, .active: false
        case .done, .failed, .cancelled: true
        }
    }
}
