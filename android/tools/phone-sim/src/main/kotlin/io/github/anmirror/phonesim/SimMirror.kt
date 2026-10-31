// phone-sim's mirror relay (F-17): stands in for the phone app and its helper. On mirror.start it dials
// the Mac's video and control links with the start's tokens, plays a canned scrcpy video stream paced by
// its timestamps, prints the touches the Mac sends, and checks that a used token is refused.
package io.github.anmirror.phonesim

import com.google.protobuf.ByteString
import io.github.anmirror.connection.BulkConnector
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.connection.ControlChannel
import io.github.anmirror.connection.TlsConnector
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.FeatureAvailability
import io.github.anmirror.protocol.v1.MirrorPhase
import io.github.anmirror.protocol.v1.MirrorReason
import io.github.anmirror.protocol.v1.MirrorStart
import io.github.anmirror.protocol.v1.MirrorState
import io.github.anmirror.protocol.v1.MirrorStop
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * A canned video socket stream (the bytes after the dummy byte): the 64-byte device name and the
 * codec ID, then packets with 12-byte headers. [chunks] splits it into the header and one chunk per
 * packet, each media packet with its PTS (µs) and config and session packets with none.
 */
internal object MirrorSample {
    class Chunk(val bytes: ByteArray, val ptsUs: Long?)

    private const val META_BYTES = 64 + 4
    private const val HEADER_BYTES = 12
    private const val PTS_MASK = (1L shl 61) - 1
    private const val CONFIG_BIT = 1L shl 62

    fun chunks(stream: ByteArray): List<Chunk> {
        require(stream.size >= META_BYTES) { "too short for the device name and codec" }
        val out = mutableListOf(Chunk(stream.copyOfRange(0, META_BYTES), null))
        var at = META_BYTES
        while (at < stream.size) {
            require(stream.size - at >= HEADER_BYTES) { "truncated packet header at $at" }
            val session = stream[at].toInt() and 0x80 != 0
            val ptsAndFlags = u64(stream, at)
            val size = if (session) 0 else u32(stream, at + 8)
            val end = at + HEADER_BYTES + size
            require(end <= stream.size) { "truncated packet at $at" }
            val media = !session && ptsAndFlags and CONFIG_BIT == 0L
            out += Chunk(stream.copyOfRange(at, end), if (media) ptsAndFlags and PTS_MASK else null)
            at = end
        }
        return out
    }

    /**
     * Writes [chunks] to [out], flushing each, a media packet no earlier than its PTS after the
     * first one's ([sleep] waits, in ns): a 60 fps sample takes a second, not one burst.
     */
    fun play(chunks: List<Chunk>, out: OutputStream, nanoTime: () -> Long = System::nanoTime, sleep: (Long) -> Unit = ::sleepNanos) {
        var startNs = 0L
        var firstPts: Long? = null
        for (chunk in chunks) {
            chunk.ptsUs?.let { pts ->
                val base = firstPts ?: pts.also { firstPts = it; startNs = nanoTime() }
                val wait = startNs + (pts - base) * 1_000 - nanoTime()
                if (wait > 0) sleep(wait)
            }
            out.write(chunk.bytes)
            out.flush()
        }
    }

    private fun sleepNanos(ns: Long) = Thread.sleep(ns / 1_000_000, (ns % 1_000_000).toInt())

    private fun u32(b: ByteArray, at: Int): Int =
        ((b[at].toInt() and 0xff) shl 24) or ((b[at + 1].toInt() and 0xff) shl 16) or ((b[at + 2].toInt() and 0xff) shl 8) or (b[at + 3].toInt() and 0xff)

    private fun u64(b: ByteArray, at: Int): Long = (u32(b, at).toLong() shl 32) or (u32(b, at + 4).toLong() and 0xffffffffL)
}

/**
 * Reads scrcpy control messages (Mac → phone) until the stream ends, calling [onTouch] with each
 * INJECT_TOUCH_EVENT's action. An unknown type stops reading (its size is unknown); it is told
 * through [onUnknown].
 */
internal fun readControl(input: InputStream, onTouch: (action: Int) -> Unit, onUnknown: (type: Int) -> Unit) {
    val din = DataInputStream(input)
    try {
        while (true) {
            when (val type = din.readUnsignedByte()) {
                0 -> din.skipNBytes(13) // INJECT_KEYCODE
                1 -> din.skipNBytes(din.readInt().toLong()) // INJECT_TEXT
                2 -> { // INJECT_TOUCH_EVENT
                    val action = din.readUnsignedByte()
                    din.skipNBytes(30)
                    onTouch(action)
                }
                3 -> din.skipNBytes(20) // INJECT_SCROLL_EVENT
                4, 8, 10 -> din.skipNBytes(1) // BACK_OR_SCREEN_ON, GET_CLIPBOARD, SET_DISPLAY_POWER
                9 -> { // SET_CLIPBOARD
                    din.skipNBytes(9)
                    din.skipNBytes(din.readInt().toLong())
                }
                5, 6, 7, 11, 15, 17 -> Unit // no payload
                else -> {
                    onUnknown(type)
                    return
                }
            }
        }
    } catch (e: EOFException) {
        // the Mac closed the link
    } catch (e: IOException) {
        // the link went away
    }
}

/**
 * `--mirror-relay`: advertises mirror.v1 and says it is enabled; plays [sample] on every
 * mirror.start; on the Mac's mirror.stop answers STOPPED USER, prints `EVENT mirror-stop`, closes
 * and calls [onDone].
 */
internal class SimMirror(
    private val channel: ControlChannel,
    connector: TlsConnector,
    private val macFingerprintHex: String,
    sample: ByteArray,
    private val emit: (String) -> Unit,
    private val onDone: () -> Unit,
) {
    private val bulk = BulkConnector(connector)
    private val chunks = MirrorSample.chunks(sample)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val links = CopyOnWriteArrayList<BulkStream>()
    @Volatile private var session: Int? = null
    @Volatile private var controlReader: Thread? = null

    suspend fun start() {
        channel.send(Channel.CHANNEL_MIRROR, MessageType.MIRROR_AVAILABILITY, FeatureAvailability.newBuilder().setEnabled(true).build())
    }

    /** Takes `mirror.*`; false for any other message. */
    suspend fun onMessage(env: Envelope): Boolean {
        when (env.type) {
            MessageType.MIRROR_START -> {
                val start = MirrorStart.parseFrom(env.payload)
                session = start.session
                scope.launch { run(start) }
            }
            MessageType.MIRROR_STOP -> {
                val stop = MirrorStop.parseFrom(env.payload)
                if (stop.session != session) return true
                sendState(stop.session, MirrorPhase.MIRROR_PHASE_STOPPED, MirrorReason.MIRROR_REASON_USER)
                emit("EVENT mirror-stop")
                // Like the phone app: the Mac's last control bytes follow its stop; read them before closing.
                withContext(Dispatchers.IO) { controlReader?.join(CONTROL_DRAIN_MS) }
                links.forEach { runCatching { it.close() } }
                onDone()
            }
            MessageType.MIRROR_TEST_PATTERN -> Unit
            else -> return false
        }
        return true
    }

    private suspend fun run(start: MirrorStart) {
        sendState(start.session, MirrorPhase.MIRROR_PHASE_STARTING)
        val (video, audio, control) = try {
            Triple(
                dial(start, BulkRole.BULK_ROLE_MIRROR_VIDEO, start.tokens.video),
                if (start.audio) dial(start, BulkRole.BULK_ROLE_MIRROR_AUDIO, start.tokens.audio) else null,
                dial(start, BulkRole.BULK_ROLE_MIRROR_CONTROL, start.tokens.control),
            )
        } catch (e: IOException) {
            sendState(start.session, MirrorPhase.MIRROR_PHASE_FAILED, MirrorReason.MIRROR_REASON_LINK_FAILED)
            emit("EVENT failed MIRROR_LINK")
            return
        }
        controlReader = thread(isDaemon = true, name = "sim-mirror-control") {
            readControl(
                control.input,
                onTouch = { emit("EVENT mirror-control type=2 action=$it") },
                onUnknown = { emit("EVENT mirror-control type=$it") },
            )
        }
        scope.launch { checkTokenReuse(start) }
        try {
            // Like the phone app: RUNNING once the dummy byte is through, before the first frame.
            video.output.write(0)
            video.output.flush()
            if (audio != null) {
                audio.output.write(byteArrayOf(0, 0, 0, 0)) // codec 0: this phone can't capture audio
                audio.output.flush()
            }
            sendState(start.session, MirrorPhase.MIRROR_PHASE_RUNNING)
            MirrorSample.play(chunks, video.output)
        } catch (e: IOException) {
            // the Mac closed the video link (its stop follows on the control channel)
        }
    }

    /** A 4th connection with the used video token: the Mac must close it without a byte. */
    private suspend fun checkTokenReuse(start: MirrorStart) {
        val gaveUp = AtomicBoolean(false)
        val result = try {
            val reused = dial(start, BulkRole.BULK_ROLE_MIRROR_VIDEO, start.tokens.video)
            val watchdog = thread(isDaemon = true, name = "sim-mirror-reuse") {
                try {
                    Thread.sleep(REUSE_WAIT_MS)
                    gaveUp.set(true)
                    runCatching { reused.close() }
                } catch (e: InterruptedException) {
                    // answered in time
                }
            }
            val first = try {
                reused.input.read()
            } catch (e: IOException) {
                -1
            }
            watchdog.interrupt()
            runCatching { reused.close() }
            when {
                gaveUp.get() -> "open"
                first < 0 -> "refused"
                else -> "accepted"
            }
        } catch (e: IOException) {
            "refused"
        }
        emit("EVENT mirror-token-reuse $result")
    }

    private suspend fun dial(start: MirrorStart, role: BulkRole, token: ByteString): BulkStream {
        val hello = BulkHello.newBuilder().setToken(token).setRole(role).build()
        return bulk.open(channel.host, start.port, macFingerprintHex, hello).also { links += it }
    }

    private suspend fun sendState(session: Int, phase: MirrorPhase, reason: MirrorReason = MirrorReason.MIRROR_REASON_UNSPECIFIED) {
        val state = MirrorState.newBuilder().setSession(session).setPhase(phase).setReason(reason).build()
        channel.send(Channel.CHANNEL_MIRROR, MessageType.MIRROR_STATE, state)
    }

    private companion object {
        const val REUSE_WAIT_MS = 5_000L
        const val CONTROL_DRAIN_MS = 500L
    }
}
