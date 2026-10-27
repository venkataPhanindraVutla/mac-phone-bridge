package io.github.anmirror.connection

import java.io.File
import java.net.Socket
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager

/** This device's certificate and private key, as presented in mutual TLS (SPEC 4). */
interface TlsIdentity {
    /** DER of the self-signed certificate; its SHA-256 is this device's fingerprint/ID. */
    val certificateDer: ByteArray

    fun keyManagers(): Array<KeyManager>
}

/** An identity read from a PKCS#12 file (tests and tools; the app uses the Android Keystore). */
class Pkcs12Identity(file: File, password: CharArray) : TlsIdentity {
    val certificate: X509Certificate
    private val privateKey: PrivateKey
    private val chain: Array<X509Certificate>

    init {
        val store = KeyStore.getInstance("PKCS12")
        file.inputStream().use { store.load(it, password) }
        val alias = store.aliases().toList().firstOrNull { store.isKeyEntry(it) }
            ?: throw IllegalArgumentException("no private key in $file")
        privateKey = store.getKey(alias, password) as PrivateKey
        chain = store.getCertificateChain(alias).map { it as X509Certificate }.toTypedArray()
        certificate = chain.first()
    }

    override val certificateDer: ByteArray get() = certificate.encoded

    override fun keyManagers(): Array<KeyManager> = arrayOf(SingleIdentityKeyManager(privateKey, chain))
}

/**
 * Always offers the one identity it holds, whatever issuers the peer lists.
 *
 * The JDK's default key managers pick a client certificate by the issuers in the server's
 * CertificateRequest. Our certificates are self-signed and trust is by pin, so a server
 * that lists any CA (or none we match) would make the default manager send no certificate
 * at all. This manager only checks that the key type fits the requested algorithm.
 */
class SingleIdentityKeyManager(
    private val privateKey: PrivateKey,
    private val chain: Array<X509Certificate>,
) : X509ExtendedKeyManager() {
    private val alias = "anmirror"

    private fun fits(keyTypes: Array<out String>?): Boolean {
        val algorithm = privateKey.algorithm
        // TLS 1.3 asks for "EC"/"RSA"/...; TLS 1.2 style types look like "EC_EC".
        return keyTypes == null || keyTypes.any { it == algorithm || it.startsWith("${algorithm}_") }
    }

    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? =
        if (fits(keyType?.let { arrayOf(it) })) arrayOf(alias) else null

    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String? =
        if (fits(keyType)) alias else null

    override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?): String? =
        if (fits(keyType)) alias else null

    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? =
        getClientAliases(keyType, issuers)

    override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? =
        if (fits(keyType?.let { arrayOf(it) })) alias else null

    override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?): String? =
        chooseServerAlias(keyType, issuers, null)

    override fun getCertificateChain(alias: String?): Array<X509Certificate>? = if (alias == this.alias) chain.clone() else null

    override fun getPrivateKey(alias: String?): PrivateKey? = if (alias == this.alias) privateKey else null
}
