import AMProtocol
import Foundation

/// Where an incoming file goes.
public enum IncomingDestination: Equatable, Sendable {
    /// Into this folder, under the offer's sanitized name made unique there.
    case folder(URL)
    /// At exactly this path, replacing what is there once the file arrived whole (file promises).
    case file(URL)
    /// Not received: the offer is rejected with this reason.
    case refuse(AMTransferError)
}

/// Why a transfer, or the request it answers, failed.
public enum TransferFailure: Error, Equatable, Sendable {
    case transfer(AMTransferError)
    case browse(AMBrowseOutcome)
}
