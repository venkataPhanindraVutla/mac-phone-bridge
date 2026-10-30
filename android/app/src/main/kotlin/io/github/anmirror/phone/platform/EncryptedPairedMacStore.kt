package io.github.anmirror.phone.platform

import android.util.AtomicFile
import android.util.Log
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PairedMacStore
import io.github.anmirror.phone.TAG
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/** Encrypts and decrypts one blob. [KeystoreCipher] in the app; a fake in tests. */
interface BlobCipher {
    fun encrypt(plain: ByteArray): ByteArray
    fun decrypt(blob: ByteArray): ByteArray
}

/** Where the blob lives: written atomically, absent until first saved. */
interface BlobFile {
    /** Null when the file does not exist. */
    fun read(): ByteArray?
    fun write(blob: ByteArray)

    /** Keeps a copy of the current blob, if any, before it is replaced. */
    fun backUp()
}

class AtomicBlobFile(private val file: AtomicFile) : BlobFile {
    override fun read(): ByteArray? = try {
        file.readFully()
    } catch (e: FileNotFoundException) {
        null
    }

    override fun write(blob: ByteArray) {
        val out = file.startWrite()
        try {
            out.write(blob)
            file.finishWrite(out)
        } catch (t: Throwable) {
            file.failWrite(out)
            throw t
        }
    }

    override fun backUp() {
        BackupRotation.keep(file.baseFile, BACKUPS)
    }
}

/** Keeps `<name>.bak1` (newest) to `.bak<keep>` copies of a file that is about to be replaced. */
object BackupRotation {
    fun keep(source: File, keep: Int) {
        if (!source.exists()) return
        fun bak(n: Int) = File(source.parentFile, "${source.name}.bak$n")
        bak(keep).delete()
        for (n in keep - 1 downTo 1) bak(n).takeIf { it.exists() }?.renameTo(bak(n + 1))
        source.copyTo(bak(1), overwrite = true)
    }
}

private const val BACKUPS = 3

/**
 * The paired Macs as one JSON list, encrypted as a single blob with [cipher] and written
 * atomically. The discovery keys in it are secrets (SPEC 6), so nothing is stored in clear.
 *
 * A store that cannot be read is never overwritten on a hunch. Anything but a
 * permanent failure (see [StoreRead.Unreadable]) makes [save] and [remove] throw [IOException] and write nothing; the caller tries
 * later. A permanent one keeps the old blob as `.bak1` to `.bak3` (newest first) and then
 * replaces it.
 */
class EncryptedPairedMacStore(
    private val file: BlobFile,
    private val cipher: BlobCipher,
    private val onUnreadable: (causeClass: String) -> Unit = {},
) : PairedMacStore {
    constructor(
        file: AtomicFile,
        cipher: KeystoreCipher,
        onUnreadable: (causeClass: String) -> Unit = {},
    ) : this(AtomicBlobFile(file), cipher, onUnreadable)

    private val lock = Mutex()

    /** 0.1's meaning for readers: unreadable reads as none. It is recorded. */
    override suspend fun all(): List<PairedMac> = lock.withLock {
        when (val r = read()) {
            is StoreRead.Macs -> r.macs
            is StoreRead.Unreadable -> {
                Log.w(TAG, "paired Macs unreadable (${r.causeClass}); treating as none")
                emptyList()
            }
        }
    }

    override suspend fun save(mac: PairedMac) = lock.withLock {
        val macs = macsForWrite()
        val i = macs.indexOfFirst { it.id == mac.id }
        store(if (i < 0) macs + mac else macs.toMutableList().also { it[i] = mac })
    }

    override suspend fun remove(id: String) = lock.withLock { store(macsForWrite().filter { it.id != id }) }

    /** What a read gave, with the unreadable case reported. */
    suspend fun readStore(): StoreRead = lock.withLock { read() }

    /** True only when the file is absent or decodes to no Macs, never for an unreadable store. */
    suspend fun confirmedEmpty(): Boolean = (readStore() as? StoreRead.Macs)?.macs?.isEmpty() == true

    private suspend fun read(): StoreRead = withContext(Dispatchers.IO) {
        val r = try {
            PairedMacsBlob.decode(file.read(), cipher::decrypt)
        } catch (e: Exception) {
            StoreRead.Unreadable(e.javaClass.simpleName)
        }
        if (r is StoreRead.Unreadable) onUnreadable(r.causeClass)
        r
    }

    private suspend fun macsForWrite(): List<PairedMac> = when (val r = read()) {
        is StoreRead.Macs -> r.macs
        is StoreRead.Unreadable -> {
            if (!r.permanent) throw IOException("paired Macs unreadable (${r.causeClass}); not writing")
            Log.w(TAG, "paired Macs unreadable (${r.causeClass}); keeping a backup and replacing")
            withContext(Dispatchers.IO) { file.backUp() }
            emptyList()
        }
    }

    private suspend fun store(macs: List<PairedMac>) = withContext(Dispatchers.IO) {
        file.write(cipher.encrypt(PairedMacsBlob.encode(macs)))
    }
}
