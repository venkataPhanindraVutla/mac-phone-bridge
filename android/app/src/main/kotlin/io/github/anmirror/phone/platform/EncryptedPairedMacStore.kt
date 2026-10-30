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
import java.io.FileNotFoundException

/**
 * The paired Macs as one JSON list, encrypted as a single blob with [cipher] and written
 * atomically. The discovery keys in it are secrets (SPEC 6), so nothing is stored in clear.
 */
class EncryptedPairedMacStore(
    private val file: AtomicFile,
    private val cipher: KeystoreCipher,
    private val onUnreadable: (causeClass: String) -> Unit = {},
) : PairedMacStore {
    private val lock = Mutex()

    override suspend fun all(): List<PairedMac> = lock.withLock { load() }

    override suspend fun save(mac: PairedMac) = lock.withLock {
        val macs = load()
        val i = macs.indexOfFirst { it.id == mac.id }
        store(if (i < 0) macs + mac else macs.toMutableList().also { it[i] = mac })
    }

    override suspend fun remove(id: String) = lock.withLock { store(load().filter { it.id != id }) }

    private suspend fun read(): StoreRead = withContext(Dispatchers.IO) {
        val blob = try {
            file.readFully()
        } catch (e: FileNotFoundException) {
            null
        }
        PairedMacsBlob.decode(blob, cipher::decrypt)
    }

    /** 0.1's meaning: unreadable reads as none, but is recorded. Writers must not use this. */
    private suspend fun load(): List<PairedMac> = when (val r = read()) {
        is StoreRead.Macs -> r.macs
        is StoreRead.Unreadable -> {
            Log.w(TAG, "paired Macs unreadable (${r.causeClass}); treating as none")
            onUnreadable(r.causeClass)
            emptyList()
        }
    }

    /** True only when the file is absent or decodes to no Macs, never for an unreadable store. */
    suspend fun confirmedEmpty(): Boolean = lock.withLock {
        when (val r = read()) {
            is StoreRead.Macs -> r.macs.isEmpty()
            is StoreRead.Unreadable -> {
                onUnreadable(r.causeClass)
                false
            }
        }
    }

    private suspend fun store(macs: List<PairedMac>) = withContext(Dispatchers.IO) {
        val blob = cipher.encrypt(PairedMacsBlob.encode(macs))
        val out = file.startWrite()
        try {
            out.write(blob)
            file.finishWrite(out)
        } catch (t: Throwable) {
            file.failWrite(out)
            throw t
        }
    }
}
