package io.github.anmirror.phone.platform

import io.github.anmirror.connection.PairedMac
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import javax.crypto.AEADBadTagException

/** What reading the paired-Macs file gave. [Unreadable] is not the same as "no Mac paired". */
sealed interface StoreRead {
    data class Macs(val macs: List<PairedMac>) : StoreRead

    /**
     * [permanent]: the blob can never be read again (it fails authentication, is too short to be
     * ours, or decrypts to something that is not the list). Everything else, including every
     * failure we do not recognise, is not permanent: the Keystore may be busy and a later read
     * may work, so nothing may overwrite the blob.
     */
    data class Unreadable(val causeClass: String, val permanent: Boolean = false) : StoreRead
}

object PairedMacsBlob {
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(PairedMac.serializer())

    /** [blob] null means the file is absent: confirmed empty. */
    fun decode(blob: ByteArray?, decrypt: (ByteArray) -> ByteArray): StoreRead {
        if (blob == null) return StoreRead.Macs(emptyList())
        val plain = try {
            decrypt(blob)
        } catch (e: Exception) {
            val perm = generateSequence<Throwable>(e) { it.cause?.takeIf { c -> c !== it } }
                .take(MAX_CHAIN)
                .firstOrNull { it is AEADBadTagException || it is CiphertextTooShortException }
            return StoreRead.Unreadable((perm ?: e).javaClass.simpleName, permanent = perm != null)
        }
        return try {
            StoreRead.Macs(json.decodeFromString(serializer, plain.decodeToString()))
        } catch (e: SerializationException) {
            StoreRead.Unreadable(e.javaClass.simpleName, permanent = true)
        }
    }

    fun encode(macs: List<PairedMac>): ByteArray = json.encodeToString(serializer, macs).encodeToByteArray()

    private const val MAX_CHAIN = 8
}
