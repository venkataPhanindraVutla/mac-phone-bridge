package io.github.anmirror.connection

import io.github.anmirror.protocol.PairingCrypto
import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedTrustManager

/** Lowercase hex, as fingerprints are stored and displayed (SPEC 4). */
internal fun ByteArray.toHex(): String {
    val digits = "0123456789abcdef"
    val sb = StringBuilder(size * 2)
    for (b in this) {
        val v = b.toInt() and 0xFF
        sb.append(digits[v shr 4]).append(digits[v and 15])
    }
    return sb.toString()
}

/** Lowercase hex SHA-256 of a certificate's DER. */
fun fingerprintHex(certificateDer: ByteArray): String = PairingCrypto.fingerprint(certificateDer).toHex()

/**
 * Trusts exactly the peers whose leaf certificate fingerprint (lowercase hex SHA-256 of the DER)
 * is in [allowed]. No CA, chain, validity or hostname check: the pin is the whole decision (SPEC 1).
 *
 * It extends [X509ExtendedTrustManager] so the JDK uses it as is, instead of wrapping a plain
 * X509TrustManager with extra endpoint/constraint checks that do not apply to pinned peers.
 */
class PinnedTrustManager(
    allowed: Set<String>,
    /** Called after a peer certificate matched a pin (lets the connector tell refusal from mismatch). */
    private val onMatch: (() -> Unit)? = null,
) : X509ExtendedTrustManager() {
    private val allowed: List<ByteArray> = allowed.map { it.lowercase().toByteArray(Charsets.US_ASCII) }

    private fun check(chain: Array<out X509Certificate>?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("no peer certificate")
        val fp = fingerprintHex(leaf.encoded).toByteArray(Charsets.US_ASCII)
        var ok = false
        for (a in allowed) if (MessageDigest.isEqual(a, fp)) ok = true
        if (!ok) throw CertificateException("peer certificate fingerprint is not pinned")
        onMatch?.invoke()
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = check(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = check(chain)
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = check(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = check(chain)
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) = check(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) = check(chain)

    /** Empty: a server using this sends no CA list (self-signed peers have none to match). */
    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}
