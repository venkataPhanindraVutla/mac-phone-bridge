package io.github.anmirror.phone.platform

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.github.anmirror.connection.SingleIdentityKeyManager
import io.github.anmirror.connection.TlsIdentity
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Calendar
import java.util.Date
import javax.net.ssl.KeyManager
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.X509KeyManager
import javax.security.auth.x500.X500Principal

/**
 * This phone's TLS identity: an EC P-256 key that never leaves the AndroidKeyStore, with a
 * self-signed certificate the Keystore makes for it. The certificate's SHA-256 is the phone's ID.
 *
 * Created on first use and kept until the app is uninstalled (or its data cleared).
 */
class AndroidKeystoreIdentity : TlsIdentity {
    private val keyStore: KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    init {
        if (!keyStore.containsAlias(ALIAS)) generate()
    }

    override val certificateDer: ByteArray
        get() = (keyStore.getCertificate(ALIAS) as X509Certificate).encoded

    /**
     * The key and chain come from a [KeyManagerFactory] over the AndroidKeyStore. They are offered
     * through [SingleIdentityKeyManager], which presents them whatever issuers the Mac lists: our
     * certificate is self-signed and trusted by pin, so an issuer filter must not drop it.
     */
    override fun keyManagers(): Array<KeyManager> {
        val factory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        factory.init(keyStore, null)
        val manager = factory.keyManagers.filterIsInstance<X509KeyManager>().first()
        val key: PrivateKey = checkNotNull(manager.getPrivateKey(ALIAS)) { "no Keystore key $ALIAS" }
        val chain: Array<X509Certificate> = checkNotNull(manager.getCertificateChain(ALIAS)) { "no chain for $ALIAS" }
        return arrayOf(SingleIdentityKeyManager(key, chain))
    }

    private fun generate() {
        val notBefore = Date()
        val notAfter = Calendar.getInstance().apply { time = notBefore; add(Calendar.YEAR, VALIDITY_YEARS) }.time
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            // NONE lets the TLS stack hash itself and ask the Keystore only to sign the digest.
            .setDigests(
                KeyProperties.DIGEST_NONE,
                KeyProperties.DIGEST_SHA256,
                KeyProperties.DIGEST_SHA384,
                KeyProperties.DIGEST_SHA512,
            )
            .setCertificateSubject(X500Principal(SUBJECT))
            .setCertificateSerialNumber(BigInteger(64, SecureRandom()).abs().add(BigInteger.ONE))
            .setCertificateNotBefore(notBefore)
            .setCertificateNotAfter(notAfter)
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE).apply {
            initialize(spec)
            generateKeyPair()
        }
    }

    companion object {
        const val ALIAS = "anmirror-phone-identity"
        const val SUBJECT = "CN=Android Mirroring Phone"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val VALIDITY_YEARS = 100
    }
}
