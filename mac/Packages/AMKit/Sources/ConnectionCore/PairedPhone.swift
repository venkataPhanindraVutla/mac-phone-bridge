import AMProtocol
import Foundation

/// A phone this Mac has paired with. `id` is the lowercase hex of the certificate fingerprint.
public struct PairedPhone: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var model: String
    public var certificateDER: Data
    public var pairedAt: Date

    public init(id: String, name: String, model: String, certificateDER: Data, pairedAt: Date) {
        self.id = id
        self.name = name
        self.model = model
        self.certificateDER = certificateDER
        self.pairedAt = pairedAt
    }

    /// SHA-256 of the certificate DER.
    public var fingerprint: Data { PairingCrypto.fingerprint(certificateDER: certificateDER) }
}
