package io.github.anmirror.adb

import java.io.Closeable
import java.io.DataInputStream
import java.io.EOFException
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * A peer on loopback that speaks the ADB wire protocol well enough for libadb: it answers the
 * client's CNXN with its own (no AUTH, no TLS: what an impostor that took adbd's old port can do,
 * since libadb checks neither), and answers every OPEN with OKAY, one WRTE of `am broadcast`'s
 * usual output and CLSE, without running anything. [onOpen] sees each service as it is opened:
 * a test makes it deliver a broadcast, as the real shell would. Shared by core/adb's and
 * feature/mirror's tests (their build files add this directory).
 */
class FakeAdbd(private val onOpen: (String) -> Unit = {}) : Closeable {
    private val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    private val sockets = CopyOnWriteArrayList<Socket>()
    private val nextId = AtomicInteger(1000)

    val port: Int get() = server.localPort

    /** Every service a client opened, in order. */
    val opened = CopyOnWriteArrayList<String>()

    /** Counts down once per client connection that ended (closed by the client, or by [close]). */
    @Volatile var ended = CountDownLatch(1)

    init {
        thread(isDaemon = true, name = "fake-adbd") {
            while (!server.isClosed) {
                val s = runCatching { server.accept() }.getOrNull() ?: break
                sockets += s
                thread(isDaemon = true, name = "fake-adbd-client") {
                    try {
                        serve(s)
                    } catch (_: Exception) {
                        // the client went away
                    } finally {
                        runCatching { s.close() }
                        ended.countDown()
                    }
                }
            }
        }
    }

    /** Waits for a client connection to end; false after [seconds]. */
    fun awaitEnded(seconds: Long = 3): Boolean = ended.await(seconds, TimeUnit.SECONDS)

    private fun serve(s: Socket) {
        val input = DataInputStream(s.getInputStream())
        val out = s.getOutputStream()
        // Our own timed TCP probe (LibAdbClient.connect) closes before sending anything.
        val hello = read(input) ?: return
        check(hello.command == CNXN) { "expected CNXN" }
        send(out, CNXN, VERSION_SKIP_CHECKSUM, MAX_DATA, "device::ro.product.name=fake;\u0000".toByteArray())
        while (true) {
            val m = read(input) ?: return
            when (m.command) {
                OPEN -> {
                    val service = String(m.payload, Charsets.UTF_8).trimEnd('\u0000')
                    opened += service
                    onOpen(service)
                    val local = m.arg0
                    val mine = nextId.incrementAndGet()
                    send(out, OKAY, mine, local)
                    send(out, WRTE, mine, local, "Broadcasting: Intent { flg=0x400000 }\nBroadcast completed: result=0\n".toByteArray())
                    send(out, CLSE, mine, local)
                }
                else -> Unit // the client's OKAYs and CLSEs
            }
        }
    }

    private class Message(val command: Int, val arg0: Int, val arg1: Int, val payload: ByteArray)

    /** Null at a clean end of stream before a header. */
    private fun read(input: DataInputStream): Message? {
        val header = ByteArray(HEADER_BYTES)
        try {
            input.readFully(header)
        } catch (e: EOFException) {
            return null
        }
        val b = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        val command = b.int
        val arg0 = b.int
        val arg1 = b.int
        val length = b.int
        val payload = ByteArray(length).also { input.readFully(it) }
        return Message(command, arg0, arg1, payload)
    }

    private fun send(out: OutputStream, command: Int, arg0: Int, arg1: Int, payload: ByteArray = ByteArray(0)) {
        val b = ByteBuffer.allocate(HEADER_BYTES + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        b.putInt(command).putInt(arg0).putInt(arg1).putInt(payload.size)
        b.putInt(payload.sumOf { it.toInt() and 0xff }).putInt(command.inv())
        b.put(payload)
        synchronized(out) {
            out.write(b.array())
            out.flush()
        }
    }

    override fun close() {
        runCatching { server.close() }
        sockets.forEach { runCatching { it.close() } }
    }

    companion object {
        private const val HEADER_BYTES = 24
        private const val CNXN = 0x4e584e43
        private const val OPEN = 0x4e45504f
        private const val OKAY = 0x59414b4f
        private const val CLSE = 0x45534c43
        private const val WRTE = 0x45545257
        private const val VERSION_SKIP_CHECKSUM = 0x01000001
        private const val MAX_DATA = 256 * 1024

        /** The nonce in an `exec:am broadcast … --es n <nonce>` service, or null. */
        fun nonceOf(service: String): String? = Regex("""^exec:am broadcast .* --es n ([0-9a-f]{32})$""").find(service)?.groupValues?.get(1)
    }
}
