package io.github.anmirror.feature.mirror

import com.google.protobuf.ByteString
import io.github.anmirror.adb.AdbClient
import io.github.anmirror.adb.AdbPipe
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.protocol.v1.AudioCodec
import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.MirrorStart
import io.github.anmirror.protocol.v1.MirrorTokens
import io.github.anmirror.protocol.v1.VideoCodec
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** An in-memory blocking pipe: [output] writes, [input] reads (blocking), [close] gives EOF once drained. */
class BytePipe {
    private val lock = ReentrantLock()
    private val changed = lock.newCondition()
    private val buffer = ArrayDeque<Byte>()
    private var closed = false

    val input: InputStream = object : InputStream() {
        override fun read(): Int {
            val b = ByteArray(1)
            return if (read(b, 0, 1) < 0) -1 else b[0].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len == 0) return 0
            lock.withLock {
                while (buffer.isEmpty() && !closed) changed.await()
                if (buffer.isEmpty()) return -1
                var n = 0
                while (n < len && buffer.isNotEmpty()) b[off + n++] = buffer.removeFirst()
                return n
            }
        }

        override fun close() = this@BytePipe.close()
    }

    val output: OutputStream = object : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        override fun write(b: ByteArray, off: Int, len: Int) {
            lock.withLock {
                if (closed) throw IOException("pipe closed")
                for (i in off until off + len) buffer.addLast(b[i])
                changed.signalAll()
            }
        }

        override fun close() = this@BytePipe.close()
    }

    fun close() {
        lock.withLock {
            closed = true
            changed.signalAll()
        }
    }

    /** Reads exactly [n] bytes (blocking). */
    fun readExactly(n: Int): ByteArray {
        val out = ByteArray(n)
        var got = 0
        while (got < n) {
            val r = input.read(out, got, n - got)
            if (r < 0) throw IOException("EOF after $got of $n")
            got += r
        }
        return out
    }
}

/** One of the helper's abstract sockets: what the helper writes ([fromHelper]) and what reaches it ([toHelper]). */
class FakeSocket(dummy: Int? = null) {
    val fromHelper = BytePipe()
    val toHelper = BytePipe()
    val closes = AtomicInteger()

    init {
        if (dummy != null) fromHelper.output.write(dummy)
    }

    fun pipe() = AdbPipe(fromHelper.input, toHelper.output) {
        closes.incrementAndGet()
        fromHelper.close()
        toHelper.close()
    }

    /** The helper went away: its end of the socket closes. */
    fun helperCloses() {
        fromHelper.close()
        toHelper.close()
    }
}

/** What an `open("localabstract:…")` does next. */
sealed interface SocketPlan {
    /** Nothing listens yet: the open fails. */
    data object Refuse : SocketPlan

    /** The open succeeds but the helper closes it before the dummy byte. */
    data object Eof : SocketPlan
    data class Open(val socket: FakeSocket) : SocketPlan
}

class MirrorAdb(private val sha: String = SHA) : AdbClient {
    @Volatile override var isConnected = true
    val shells = CopyOnWriteArrayList<String>()
    val opens = CopyOnWriteArrayList<String>()
    val pushed = ByteArrayOutputStream()
    val plan = ArrayDeque<SocketPlan>()
    val shellStream = FakeSocket()

    /** The pushed jar's sha256sum line; replace to fail the check. */
    @Volatile var shaLine: (Int) -> String = { "$sha  ${ServerCommand.JAR_PATH}\n" }
    private val shaCalls = AtomicInteger()

    override suspend fun pair(host: String, port: Int, code: String) = throw UnsupportedOperationException()
    override suspend fun connect(host: String, port: Int) = throw UnsupportedOperationException()

    override suspend fun shell(command: String): String {
        if (!isConnected) throw IOException("adb not connected")
        shells += command
        return if (command.startsWith("sha256sum ")) shaLine(shaCalls.incrementAndGet()) else ""
    }

    override suspend fun open(service: String): AdbPipe {
        if (!isConnected) throw IOException("adb not connected")
        opens += service
        return when {
            service.startsWith("exec:cat > ") -> AdbPipe(InputStream.nullInputStream(), pushed) {}
            service.startsWith("shell:") -> shellStream.pipe()
            service.startsWith("localabstract:") -> when (val next = synchronized(plan) { plan.removeFirstOrNull() } ?: SocketPlan.Refuse) {
                SocketPlan.Refuse -> throw IOException("refused")
                SocketPlan.Eof -> FakeSocket().also { it.helperCloses() }.pipe()
                is SocketPlan.Open -> next.socket.pipe()
            }
            else -> throw IOException("unexpected $service")
        }
    }

    override fun close() {
        isConnected = false
    }

    companion object {
        const val SHA = "c7143a40aa"
    }
}

/** A bulk link to the Mac: what the Mac sends ([fromMac]) and what reaches it ([toMac]). */
class FakeLink(val role: BulkRole, val token: ByteString) : BulkStream {
    val fromMac = BytePipe()
    val toMac = BytePipe()
    val closes = AtomicInteger()
    @Volatile var sendBuffer: Int? = null

    override val input: InputStream = fromMac.input
    override val output: OutputStream = toMac.output

    override fun setSendBufferBytes(n: Int) {
        sendBuffer = n
    }

    override fun close() {
        closes.incrementAndGet()
        fromMac.close()
        toMac.close()
    }

    /** The Mac closed its end. */
    fun macCloses() {
        fromMac.close()
    }
}

class FakeDialer(private val failOn: BulkRole? = null) : LinkDialer {
    val links = CopyOnWriteArrayList<FakeLink>()

    override suspend fun dial(role: BulkRole, token: ByteString): BulkStream {
        if (role == failOn) throw IOException("dial failed")
        return FakeLink(role, token).also { links += it }
    }

    fun link(role: BulkRole): FakeLink = links.first { it.role == role }
}

fun mirrorStart(session: Int = 1, audio: Boolean = true): MirrorStart = MirrorStart.newBuilder()
    .setSession(session)
    .setPort(50_000)
    .setTokens(
        MirrorTokens.newBuilder()
            .setVideo(ByteString.copyFrom(ByteArray(32) { 1 }))
            .setAudio(if (audio) ByteString.copyFrom(ByteArray(32) { 2 }) else ByteString.EMPTY)
            .setControl(ByteString.copyFrom(ByteArray(32) { 3 })),
    )
    .setMaxSize(1920)
    .setVideoBitRate(8_000_000)
    .setMaxFps(60)
    .setVideoCodec(VideoCodec.VIDEO_CODEC_H264)
    .setAudio(audio)
    .setAudioCodec(AudioCodec.AUDIO_CODEC_OPUS)
    .build()
