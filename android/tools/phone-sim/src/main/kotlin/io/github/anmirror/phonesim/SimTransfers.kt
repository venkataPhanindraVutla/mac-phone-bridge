// phone-sim's file transfers (F-04): the real :core:transfer engine over real TLS, with a seeded source
// and a temp-file sink. Prints only sizes, hashes of synthetic data and rates, never names.
package io.github.anmirror.phonesim

import com.google.protobuf.MessageLite
import io.github.anmirror.connection.BulkConnector
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.connection.ControlChannel
import io.github.anmirror.connection.TlsConnector
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.BulkEndpoint
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.TransferOffer
import io.github.anmirror.transfer.BulkOpener
import io.github.anmirror.transfer.Direction
import io.github.anmirror.transfer.IncomingFile
import io.github.anmirror.transfer.IncomingSinks
import io.github.anmirror.transfer.OutgoingFile
import io.github.anmirror.transfer.SinkResult
import io.github.anmirror.transfer.TransferEngine
import io.github.anmirror.transfer.TransferState
import io.github.anmirror.transfer.TransferStatus
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/** Deterministic test bytes: byte i = (i*131 + (i shr 8)*7 + 17) and 0xff. scripts/interop-test.sh recomputes it. */
internal class SeededInput(private val size: Long) : InputStream() {
    private var pos = 0L

    override fun read(): Int {
        if (pos >= size) return -1
        return byteAt(pos++)
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (pos >= size) return -1
        val n = minOf(len.toLong(), size - pos).toInt()
        for (i in 0 until n) b[off + i] = byteAt(pos + i).toByte()
        pos += n
        return n
    }

    private fun byteAt(i: Long): Int = ((i * 131 + (i shr 8) * 7 + 17) and 0xff).toInt()
}

private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

private fun sha256Hex(file: File): String {
    val md = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buf = ByteArray(1 shl 20)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            md.update(buf, 0, n)
        }
    }
    return hex(md.digest())
}

/**
 * One transfer session on a connected [channel]: sends [sendBytes] seeded bytes, stores what the
 * Mac sends in a temp dir, prints `files-received`, and calls [onResult] once both directions end.
 */
internal class SimTransfers(
    private val channel: ControlChannel,
    private val connector: TlsConnector,
    private val macFingerprintHex: String,
    private val sendBytes: Long,
    private val tempDir: File,
    private val emit: (String) -> Unit,
    private val onResult: (ok: Boolean) -> Unit,
) {
    // A SupervisorJob: an orphaned bulk dial that throws must not cancel the whole scope.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val port = CompletableDeferred<Int>()
    private val received = ConcurrentHashMap<String, File>()
    private val startedAt = ConcurrentHashMap<String, Long>()
    private val finished = ConcurrentHashMap.newKeySet<String>()

    private val engine = TransferEngine(
        scope = scope,
        send = { type: String, payload: MessageLite ->
            try {
                channel.send(Channel.CHANNEL_FILES, type, payload)
                true
            } catch (e: IOException) {
                false
            }
        },
        bulk = BulkOpener { hello: BulkHello -> dial(hello) },
        sinks = IncomingSinks { offer -> SinkResult.Ready(sink(offer)) },
        freeBytes = { null },
    )

    private suspend fun dial(hello: BulkHello): BulkStream {
        val p = withTimeout(10_000) { port.await() }
        return BulkConnector(connector).open(channel.host, p, macFingerprintHex, hello)
    }

    private fun sink(offer: TransferOffer): IncomingFile {
        val file = File.createTempFile("recv-", ".part", tempDir)
        received[offer.transferId] = file
        val out = FileOutputStream(file)
        return object : IncomingFile {
            override val output: OutputStream = out
            override fun commit(): String {
                out.close()
                return offer.transferId
            }
            override fun abort() {
                runCatching { out.close() }
                file.delete()
            }
        }
    }

    fun start() {
        val file = object : OutgoingFile {
            override val name = "sim.bin"
            override val size = sendBytes
            override val mime = "application/octet-stream"
            override val modifiedMs = 0L
            override fun open(): InputStream = SeededInput(sendBytes)
        }
        engine.send(listOf(file))
        scope.launch { engine.transfers.collect(::onTransfers) }
    }

    /** Routes a control message: the engine takes `files.*`; the endpoint message is ours. */
    suspend fun onMessage(env: Envelope): Boolean {
        if (env.type == MessageType.FILES_ENDPOINT) {
            port.complete(BulkEndpoint.parseFrom(env.payload).port)
            return true
        }
        return engine.onMessage(env)
    }

    fun onDisconnected() {
        engine.onDisconnected()
        scope.cancel()
    }

    private fun onTransfers(list: List<TransferStatus>) {
        for (t in list) {
            if (t.direction == Direction.RECEIVE) startedAt.putIfAbsent(t.id, System.nanoTime())
            if (t.state != TransferState.DONE && t.state != TransferState.FAILED && t.state != TransferState.CANCELLED) continue
            if (!finished.add(t.id)) continue
            if (t.state != TransferState.DONE) {
                emit("EVENT files-failed ${t.id} ${t.error ?: t.state}")
                onResult(false)
                return
            }
            if (t.direction == Direction.RECEIVE) {
                val file = received.getValue(t.id)
                val seconds = (System.nanoTime() - startedAt.getValue(t.id)) / 1e9
                val mbps = if (seconds > 0) t.size / 1e6 / seconds else 0.0
                emit("EVENT files-received bytes=${t.size} sha256=${sha256Hex(file)} mbps=${String.format(Locale.ROOT, "%.1f", mbps)}")
                file.delete()
            } else {
                emit("EVENT files-sent bytes=${t.size}")
            }
            if (finished.size == 2) onResult(true)
        }
    }
}
