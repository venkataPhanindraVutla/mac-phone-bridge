package io.github.anmirror.connection

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/** A Mac this phone has paired with. [id] is the Mac's fingerprint hex (SPEC 4). */
@Serializable
data class PairedMac(
    val id: String,
    val name: String,
    val fingerprintHex: String,
    @Serializable(with = HexBytesSerializer::class) val discoveryKey: ByteArray,
    val lastHost: String?,
    val lastPort: Int?,
    val lastConnectedAt: Long,
) {
    override fun equals(other: Any?): Boolean =
        other is PairedMac && id == other.id && name == other.name && fingerprintHex == other.fingerprintHex &&
            discoveryKey.contentEquals(other.discoveryKey) && lastHost == other.lastHost &&
            lastPort == other.lastPort && lastConnectedAt == other.lastConnectedAt

    override fun hashCode(): Int {
        var h = id.hashCode()
        h = 31 * h + name.hashCode()
        h = 31 * h + fingerprintHex.hashCode()
        h = 31 * h + discoveryKey.contentHashCode()
        h = 31 * h + (lastHost?.hashCode() ?: 0)
        h = 31 * h + (lastPort ?: 0)
        h = 31 * h + lastConnectedAt.hashCode()
        return h
    }

    // The discovery key must not leak into logs.
    override fun toString(): String =
        "PairedMac(id=$id, name=$name, lastHost=$lastHost, lastPort=$lastPort, lastConnectedAt=$lastConnectedAt)"
}

interface PairedMacStore {
    suspend fun all(): List<PairedMac>

    /** Inserts, or replaces the Mac with the same [PairedMac.id]. */
    suspend fun save(mac: PairedMac)

    suspend fun remove(id: String)
}

class InMemoryPairedMacStore(initial: List<PairedMac> = emptyList()) : PairedMacStore {
    private val lock = Mutex()
    private var macs: List<PairedMac> = initial.toList()

    override suspend fun all(): List<PairedMac> = lock.withLock { macs }

    override suspend fun save(mac: PairedMac) = lock.withLock { macs = macs.upsert(mac) }

    override suspend fun remove(id: String) = lock.withLock { macs = macs.filter { it.id != id } }
}

/** A JSON file holding a list of [PairedMac] (tools and tests; the app keeps its own store). */
class JsonFilePairedMacStore(private val file: File) : PairedMacStore {
    private val lock = Mutex()
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }
    private val serializer = ListSerializer(PairedMac.serializer())

    override suspend fun all(): List<PairedMac> = lock.withLock { load() }

    override suspend fun save(mac: PairedMac) = lock.withLock { store(load().upsert(mac)) }

    override suspend fun remove(id: String) = lock.withLock { store(load().filter { it.id != id }) }

    private suspend fun load(): List<PairedMac> = withContext(Dispatchers.IO) {
        if (!file.exists()) emptyList() else json.decodeFromString(serializer, file.readText())
    }

    private suspend fun store(macs: List<PairedMac>) {
        withContext(Dispatchers.IO) {
            file.absoluteFile.parentFile?.mkdirs()
            val tmp = File(file.absoluteFile.parentFile, "${file.name}.tmp")
            tmp.writeText(json.encodeToString(serializer, macs) + "\n")
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        }
    }
}

private fun List<PairedMac>.upsert(mac: PairedMac): List<PairedMac> {
    val i = indexOfFirst { it.id == mac.id }
    return if (i < 0) this + mac else toMutableList().also { it[i] = mac }
}

/** ByteArray as lowercase hex in JSON. */
internal object HexBytesSerializer : KSerializer<ByteArray> {
    override val descriptor = PrimitiveSerialDescriptor("io.github.anmirror.HexBytes", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: ByteArray) = encoder.encodeString(value.toHex())

    override fun deserialize(decoder: Decoder): ByteArray {
        val s = decoder.decodeString()
        require(s.length % 2 == 0) { "odd-length hex" }
        return ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }
}
