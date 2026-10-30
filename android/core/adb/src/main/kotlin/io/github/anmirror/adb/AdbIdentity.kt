package io.github.anmirror.adb

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.ByteArrayInputStream
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.time.Instant
import java.time.ZoneOffset
import java.util.Date

/**
 * The key and certificate this phone's app shows Wireless debugging: pairing trusts the
 * certificate's key, and every later connection presents both. A secret: stored encrypted, never
 * logged, never backed up.
 */
class AdbIdentity(val privateKey: PrivateKey, val certificate: X509Certificate) {
    /** The private key, PKCS#8 DER. */
    fun encodedKey(): ByteArray = privateKey.encoded

    /** The certificate, X.509 DER. */
    fun encodedCertificate(): ByteArray = certificate.encoded

    companion object {
        private const val KEY_BITS = 2048
        private const val VALID_YEARS = 10L

        /** RSA-2048 with a self-signed SHA512withRSA certificate, `CN=<name>`, valid for 10 years from [nowMs]. */
        fun generate(name: String = "Android Mirroring", nowMs: Long = System.currentTimeMillis()): AdbIdentity {
            val keys = KeyPairGenerator.getInstance("RSA").apply { initialize(KEY_BITS, SecureRandom()) }.generateKeyPair()
            val subject = X500Name("CN=$name")
            val from = Instant.ofEpochMilli(nowMs)
            val until = from.atZone(ZoneOffset.UTC).plusYears(VALID_YEARS).toInstant()
            val serial = BigInteger(63, SecureRandom()).add(BigInteger.ONE)
            val holder = JcaX509v3CertificateBuilder(subject, serial, Date.from(from), Date.from(until), subject, keys.public)
                .build(JcaContentSignerBuilder("SHA512withRSA").build(keys.private))
            return AdbIdentity(keys.private, JcaX509CertificateConverter().getCertificate(holder))
        }

        /** The inverse of [encodedKey] and [encodedCertificate]. */
        fun decode(pkcs8: ByteArray, der: ByteArray): AdbIdentity {
            val key = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(pkcs8))
            val cert = CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(der)) as X509Certificate
            return AdbIdentity(key, cert)
        }
    }
}
