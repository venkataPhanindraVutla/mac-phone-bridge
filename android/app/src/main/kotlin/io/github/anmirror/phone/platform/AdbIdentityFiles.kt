package io.github.anmirror.phone.platform

import android.util.AtomicFile
import io.github.anmirror.adb.AdbIdentity
import io.github.anmirror.feature.mirror.IdentityHolder
import java.io.File

/**
 * Full mode's ADB identity in `filesDir/adb/`: the private key (`key.bin`) and the certificate
 * (`cert.bin`), each encrypted with [cipher] and written atomically. Excluded from backup
 * (`data_extraction_rules.xml`), never logged. A pair that can't be read loads as none, so the
 * setup asks to pair again; [onUnreadable] gets the failure's class.
 */
class AdbIdentityFiles(
    private val dir: File,
    private val cipher: BlobCipher,
    private val onUnreadable: (causeClass: String) -> Unit = {},
) : IdentityHolder {
    private val key = AtomicFile(File(dir, "key.bin"))
    private val cert = AtomicFile(File(dir, "cert.bin"))
    private val lock = Any()
    private var cached: AdbIdentity? = null

    override fun load(): AdbIdentity? = synchronized(lock) {
        cached?.let { return it }
        val keyBlob = AtomicBlobFile(key).read() ?: return null
        val certBlob = AtomicBlobFile(cert).read() ?: return null
        return try {
            AdbIdentity.decode(cipher.decrypt(keyBlob), cipher.decrypt(certBlob)).also { cached = it }
        } catch (e: Exception) {
            onUnreadable(e.javaClass.simpleName)
            null
        }
    }

    override fun create(): AdbIdentity = synchronized(lock) {
        val made = AdbIdentity.generate()
        dir.mkdirs()
        AtomicBlobFile(key).write(cipher.encrypt(made.encodedKey()))
        AtomicBlobFile(cert).write(cipher.encrypt(made.encodedCertificate()))
        cached = made
        made
    }

    override fun delete() = synchronized(lock) {
        cached = null
        key.delete()
        cert.delete()
    }
}
