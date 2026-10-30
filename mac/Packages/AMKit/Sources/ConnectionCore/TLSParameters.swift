import AMProtocol
import Foundation
import Network
import Security

/// Network.framework parameters for the protocol's transport: TCP plus mutual TLS 1.3,
/// with the peer pinned by certificate fingerprint (SPEC sections 1 and 4).
///
/// Certificates are self-signed, so default trust evaluation would always fail. The verify
/// block below is therefore the whole trust decision: it hashes the peer's leaf certificate
/// and asks `acceptPeer`. Nothing else is consulted.
public enum TLSParameters {
    private static let verifyQueue = DispatchQueue(label: "io.github.anmirror.tls-verify")

    /// TCP keepalive on every control and bulk socket (SPEC 1): seconds idle before the first
    /// probe, seconds between probes, and probes before the connection fails. Defence in depth
    /// only: a frozen app's kernel still answers probes, so SPEC 7's pings do the real work.
    static let keepaliveIdleSeconds = 60
    static let keepaliveIntervalSeconds = 10
    static let keepaliveProbeCount = 3

    /// The Mac side: TLS server that requires a client certificate.
    public static func server(identity: TLSIdentity,
                              acceptPeer: @escaping @Sendable (Data) -> Bool) -> NWParameters {
        let tls = makeTLSOptions(identity: identity, acceptPeer: acceptPeer)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        let tcp = makeTCPOptions()
        let params = NWParameters(tls: tls, tcp: tcp)
        // Lets `MacServer.handleWake()` rebind the same port right after closing it.
        params.allowLocalEndpointReuse = true
        return params
    }

    /// The phone side: TLS client presenting `identity` and pinning the server.
    /// Used by tests and tools; the Android app has its own implementation.
    public static func client(identity: TLSIdentity, connectTimeoutSeconds: Int = 3,
                              acceptPeer: @escaping @Sendable (Data) -> Bool) -> NWParameters {
        let tls = makeTLSOptions(identity: identity, acceptPeer: acceptPeer)
        let tcp = makeTCPOptions()
        tcp.connectionTimeout = connectTimeoutSeconds
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// SHA-256 of the leaf certificate in `trust`, or nil if there is none.
    static func leafFingerprint(_ trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        return PairingCrypto.fingerprint(certificateDER: SecCertificateCopyData(leaf) as Data)
    }

    private static func makeTCPOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepaliveIdleSeconds
        tcp.keepaliveInterval = keepaliveIntervalSeconds
        tcp.keepaliveCount = keepaliveProbeCount
        return tcp
    }

    private static func makeTLSOptions(identity: TLSIdentity,
                                       acceptPeer: @escaping @Sendable (Data) -> Bool) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        if let local = sec_identity_create(identity.secIdentity) {
            sec_protocol_options_set_local_identity(sec, local)
        }
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let fp = leafFingerprint(secTrust) else {
                complete(false)
                return
            }
            complete(acceptPeer(fp))
        }, verifyQueue)
        return tls
    }
}
