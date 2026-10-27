package io.github.anmirror.connection

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.Frame
import io.github.anmirror.protocol.FrameDecoder
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.PairingCrypto
import io.github.anmirror.protocol.envelope
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.ErrorCode
import io.github.anmirror.protocol.v1.Hello
import io.github.anmirror.protocol.v1.SetupLevel
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import kotlin.concurrent.thread
import io.github.anmirror.protocol.v1.Error as ProtoError

fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

fun String.unhex(): ByteArray = ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }

/** The committed test-only identities (protocol/testdata/identities, password "test"). */
object Identities {
    private val dir = File(checkNotNull(System.getProperty("anmirror.identities")) { "anmirror.identities not set" })

    // protocol/vectors/crypto.json, "fingerprints".
    const val MAC_FP = "d72e52ca22350ec5c1cb484b283acecbde44cac5bdf08af75e0091a158332b70"
    const val PHONE_FP = "f25927903aad94680853cb173d5eaa08306289907646a2cfbf9177b85ec4697a"
    const val STRANGER_FP = "b2dbb0a6fadbb75841bd74284415a5de9e747c379272e9ff272c21732dfdd97b"

    val mac: TlsIdentity by lazy { Pkcs12Identity(File(dir, "mac.p12"), "test".toCharArray()) }
    val phone: TlsIdentity by lazy { Pkcs12Identity(File(dir, "phone.p12"), "test".toCharArray()) }
    val stranger: TlsIdentity by lazy { Pkcs12Identity(File(dir, "stranger.p12"), "test".toCharArray()) }
}

val CAPS = listOf("find.v1", "status.v1")

fun phoneHello(caps: List<String> = CAPS): Hello = Hello.newBuilder()
    .setProtocolVersion(1)
    .setAppVersion("0.1.0-test")
    .addAllCapabilities(caps)
    .setSetupLevel(SetupLevel.SETUP_LEVEL_BASIC)
    .setDeviceName("Test Phone")
    .setDeviceModel("Pixel Test")
    .build()

fun macHello(caps: List<String> = CAPS, version: Int = 1): Hello = Hello.newBuilder()
    .setProtocolVersion(version)
    .setAppVersion("0.1.0-test")
    .addAllCapabilities(caps)
    .setDeviceName("Test Mac")
    .setDeviceModel("Mac")
    .build()

fun errorOf(code: ErrorCode): ProtoError = ProtoError.newBuilder().setCode(code).setMessage(code.name).build()

/**
 * A tiny TLS 1.3 server playing the Mac's side of the spec sequence. Each accepted
 * connection runs [script] on its own thread. Only for tests.
 */
class TestMacServer(
    identity: TlsIdentity = Identities.mac,
    allowedClients: Set<String> = setOf(Identities.PHONE_FP),
    private val script: (MacConn) -> Unit,
) : Closeable {
    private val server: SSLServerSocket
    private val handlers = CopyOnWriteArrayList<Thread>()
    val failures = ConcurrentLinkedQueue<Throwable>()

    /** Connections whose TLS handshake completed and whose script started. */
    val scriptsStarted = AtomicInteger()

    val port: Int get() = server.localPort

    init {
        val context = SSLContext.getInstance("TLSv1.3")
        context.init(identity.keyManagers(), arrayOf(PinnedTrustManager(allowedClients)), null)
        server = context.serverSocketFactory.createServerSocket(0, 50, InetAddress.getLoopbackAddress()) as SSLServerSocket
        server.enabledProtocols = arrayOf("TLSv1.3")
        server.needClientAuth = true
        thread(isDaemon = true, name = "test-mac-accept") {
            while (!server.isClosed) {
                val socket = try {
                    server.accept() as SSLSocket
                } catch (e: IOException) {
                    break
                }
                handlers += thread(isDaemon = true, name = "test-mac-conn") { handle(socket) }
            }
        }
    }

    private fun handle(socket: SSLSocket) {
        try {
            socket.soTimeout = 10_000
            socket.startHandshake()
            scriptsStarted.incrementAndGet()
            script(MacConn(socket))
        } catch (t: Throwable) {
            failures += t
        } finally {
            runCatching { socket.close() }
        }
    }

    /** Waits for every connection script to finish, then rethrows the first failure. */
    fun join(timeoutMs: Long = 10_000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        for (t in handlers) t.join(maxOf(1, deadline - System.currentTimeMillis()))
        failures.firstOrNull()?.let { throw AssertionError("Mac script failed: $it", it) }
    }

    override fun close() {
        runCatching { server.close() }
    }
}

/** One accepted connection on the test Mac: blocking, framed reads and writes. */
class MacConn(val socket: SSLSocket) {
    private val decoder = FrameDecoder()
    private var nextId = 1L
    val peerFingerprintHex: String =
        PairingCrypto.fingerprint(socket.session.peerCertificates[0].encoded).hex()

    /** The next envelope, or null on EOF. Throws [SocketTimeoutException] after [timeoutMs]. */
    fun read(timeoutMs: Int = 5_000): Envelope? {
        socket.soTimeout = timeoutMs
        val buf = ByteArray(8192)
        while (true) {
            decoder.next()?.let { return it }
            val n = socket.inputStream.read(buf)
            if (n < 0) return null
            decoder.append(buf, 0, n)
        }
    }

    fun expect(type: String, timeoutMs: Int = 5_000): Envelope {
        val e = read(timeoutMs) ?: throw AssertionError("EOF while waiting for $type")
        if (e.type != type) throw AssertionError("expected $type, got ${e.type}")
        return e
    }

    /** True if the phone closed the connection (EOF) within [timeoutMs]. */
    fun awaitEof(timeoutMs: Int = 5_000): Boolean = try {
        read(timeoutMs) == null
    } catch (e: SocketTimeoutException) {
        false
    } catch (e: IOException) {
        true
    }

    @Synchronized
    fun send(channel: Channel, type: String, payload: MessageLite, replyTo: Long = 0): Long {
        val id = nextId++
        socket.outputStream.write(Frame.encode(envelope(channel, id, type, payload, replyTo)))
        socket.outputStream.flush()
        return id
    }

    fun sendError(code: ErrorCode) = send(Channel.CHANNEL_SYSTEM, MessageType.ERROR, errorOf(code))

    /** Answers the phone's hello (which must be the next message). */
    fun answerHello(caps: List<String> = CAPS): Hello {
        val hello = expect(MessageType.HELLO)
        send(Channel.CHANNEL_SYSTEM, MessageType.HELLO, macHello(caps), hello.id)
        return Hello.parseFrom(hello.payload)
    }
}
