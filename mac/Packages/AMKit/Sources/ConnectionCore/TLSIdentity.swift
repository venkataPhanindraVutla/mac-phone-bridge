import AMProtocol
import Foundation
import Security
import SwiftASN1
import X509

/// A certificate plus private key that TLS can present, and its pinned fingerprint.
public struct TLSIdentity: @unchecked Sendable {
    // SecIdentity is an immutable CF object; sharing it across threads is safe.
    public let secIdentity: SecIdentity
    public let certificateDER: Data

    public init(secIdentity: SecIdentity, certificateDER: Data) {
        self.secIdentity = secIdentity
        self.certificateDER = certificateDER
    }

    /// SHA-256 of the certificate DER (SPEC section 4).
    public var fingerprint: Data { PairingCrypto.fingerprint(certificateDER: certificateDER) }

    /// Lowercase hex of `fingerprint`: the device ID.
    public var deviceID: String { fingerprint.lowercaseHex }

    init(secIdentity: SecIdentity) throws {
        var cert: SecCertificate?
        let status = SecIdentityCopyCertificate(secIdentity, &cert)
        guard status == errSecSuccess, let cert else { throw IdentityError.keychain(status) }
        self.init(secIdentity: secIdentity, certificateDER: SecCertificateCopyData(cert) as Data)
    }
}

public protocol IdentityProvider: Sendable {
    func identity() throws -> TLSIdentity
}

public enum IdentityError: Error, Equatable, Sendable {
    /// In-memory PKCS#12 import needs macOS 15.
    case unsupported
    case importFailed(OSStatus)
    case noIdentityInFile
    case keychain(OSStatus)
    case certificateCreation(String)
}

/// Loads an identity from a PKCS#12 file into process memory only. For tests and
/// `am-mac-sim`; the app uses `KeychainIdentityProvider`.
public struct P12IdentityProvider: IdentityProvider {
    public let url: URL
    public let password: String

    public init(url: URL, password: String) {
        self.url = url
        self.password = password
    }

    public func identity() throws -> TLSIdentity {
        guard #available(macOS 15, *) else { throw IdentityError.unsupported }
        let data = try Data(contentsOf: url)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw IdentityError.importFailed(status) }
        guard let list = items as? [[String: Any]],
              let first = list.first,
              let raw = first[kSecImportItemIdentity as String]
        else { throw IdentityError.noIdentityInFile }
        // swiftlint:disable:next force_cast
        return try TLSIdentity(secIdentity: raw as! SecIdentity)
    }
}

/// The Mac's own long-lived identity in the login keychain (legacy file keychain; the
/// data-protection keychain needs a paid team). On first use it creates a permanent P-256
/// key and a self-signed certificate, both labelled `label`.
public struct KeychainIdentityProvider: IdentityProvider {
    public static let defaultLabel = "io.github.anmirror.mac.identity"
    public static let commonName = "Android Mirroring Mac"

    public let label: String

    public init(label: String = KeychainIdentityProvider.defaultLabel) {
        self.label = label
    }

    public func identity() throws -> TLSIdentity {
        if let cert = try findCertificate(), let identity = identity(for: cert) {
            return try TLSIdentity(secIdentity: identity)
        }
        // A certificate without its key (or the other way round) is unusable: start over.
        try deleteCertificates()
        let key = try findPrivateKey() ?? createPrivateKey()
        let der = try makeSelfSignedCertificate(key: key)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.certificateCreation("SecCertificateCreateWithData failed")
        }
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label,
            kSecUseDataProtectionKeychain as String: false,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw IdentityError.keychain(status)
        }
        guard let identity = identity(for: cert) else { throw IdentityError.keychain(errSecItemNotFound) }
        return try TLSIdentity(secIdentity: identity)
    }

    // MARK: keychain helpers

    private var tag: Data { Data(label.utf8) }

    private func identity(for cert: SecCertificate) -> SecIdentity? {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
        return status == errSecSuccess ? identity : nil
    }

    private func findCertificate() throws -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: false,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result else { throw IdentityError.keychain(status) }
        // swiftlint:disable:next force_cast
        return (result as! SecCertificate)
    }

    private func deleteCertificates() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecUseDataProtectionKeychain as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychain(status)
        }
    }

    private func findPrivateKey() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: false,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result else { throw IdentityError.keychain(status) }
        // swiftlint:disable:next force_cast
        return (result as! SecKey)
    }

    private func createPrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecUseDataProtectionKeychain as String: false,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: label,
                kSecAttrApplicationTag as String: tag,
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            throw IdentityError.certificateCreation("SecKeyCreateRandomKey: \(message)")
        }
        return key
    }

    private func makeSelfSignedCertificate(key: SecKey) throws -> Data {
        do {
            let signer = try Certificate.PrivateKey(key)
            let name = try DistinguishedName { CommonName(Self.commonName) }
            let now = Date()
            let certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: signer.publicKey,
                notValidBefore: now.addingTimeInterval(-3600),
                notValidAfter: now.addingTimeInterval(100 * 365.25 * 86_400),
                issuer: name,
                subject: name,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    Critical(KeyUsage(digitalSignature: true))
                    try ExtendedKeyUsage([.serverAuth, .clientAuth])
                },
                issuerPrivateKey: signer
            )
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            return Data(serializer.serializedBytes)
        } catch {
            throw IdentityError.certificateCreation(String(describing: error))
        }
    }
}

extension Data {
    /// Lowercase hex, two characters per byte.
    public var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}
