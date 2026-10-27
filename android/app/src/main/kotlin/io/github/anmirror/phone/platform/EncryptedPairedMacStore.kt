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
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.FileNotFoundException
import java.security.GeneralSecurityException
import java.security.ProviderException

/**
 * The paired Macs as one JSON list, encrypted as a single blob with [cipher] and written
 * atomically. The discovery keys in it are secrets (SPEC 6), so nothing is stored in clear.
 */
class EncryptedPairedMacStore(
    private val file: AtomicFile,
    private val cipher: KeystoreCipher,
) : PairedMacStore {
    private val lock = Mutex()
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(PairedMac.serializer())

    override suspend fun all(): List<PairedMac> = lock.withLock { load() }

    override suspend fun save(mac: PairedMac) = lock.withLock {
        val macs = load()
        val i = macs.indexOfFirst { it.id == mac.id }
        store(if (i < 0) macs + mac else macs.toMutableList().also { it[i] = mac })
    }

    override suspend fun remove(id: String) = lock.withLock { store(load().filter { it.id != id }) }

    private suspend fun load(): List<PairedMac> = withContext(Dispatchers.IO) {
        val blob = try {
            file.readFully()
        } catch (e: FileNotFoundException) {
            return@withContext emptyList()
        }
        try {
            json.decodeFromString(serializer, cipher.decrypt(blob).decodeToString())
        } catch (e: GeneralSecurityException) {
            unreadable(e)
        } catch (e: ProviderException) {
            // Keystore failures often surface as ProviderException (e.g. KeyStoreException).
            unreadable(e)
        } catch (e: SerializationException) {
            unreadable(e)
        }
    }

    /**
     * The Keystore key is gone (data restored elsewhere, Keystore reset) or the blob is damaged:
     * the pairings cannot be read. Treated as none; the next save replaces the file.
     */
    private fun unreadable(e: Exception): List<PairedMac> {
        Log.w(TAG, "paired Macs unreadable (${e.javaClass.simpleName}); treating as none")
        return emptyList()
    }

    private suspend fun store(macs: List<PairedMac>) = withContext(Dispatchers.IO) {
        val blob = cipher.encrypt(json.encodeToString(serializer, macs).encodeToByteArray())
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
