package io.github.anmirror.phone.platform

import io.github.anmirror.connection.PairedMac
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.security.GeneralSecurityException
import java.security.ProviderException

/** What reading the paired-Macs file gave. [Unreadable] is not the same as "no Mac paired". */
sealed interface StoreRead {
    data class Macs(val macs: List<PairedMac>) : StoreRead
    data class Unreadable(val causeClass: String) : StoreRead
}

object PairedMacsBlob {
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(PairedMac.serializer())

    /** [blob] null means the file is absent: confirmed empty. */
    fun decode(blob: ByteArray?, decrypt: (ByteArray) -> ByteArray): StoreRead {
        if (blob == null) return StoreRead.Macs(emptyList())
        return try {
            StoreRead.Macs(json.decodeFromString(serializer, decrypt(blob).decodeToString()))
        } catch (e: GeneralSecurityException) {
            StoreRead.Unreadable(e.javaClass.simpleName)
        } catch (e: ProviderException) {
            // Keystore failures often surface as ProviderException (e.g. KeyStoreException).
            StoreRead.Unreadable(e.javaClass.simpleName)
        } catch (e: SerializationException) {
            StoreRead.Unreadable(e.javaClass.simpleName)
        }
    }

    fun encode(macs: List<PairedMac>): ByteArray = json.encodeToString(serializer, macs).encodeToByteArray()
}
