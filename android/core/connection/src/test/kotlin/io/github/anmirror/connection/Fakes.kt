package io.github.anmirror.connection

import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.ErrorCode
import io.github.anmirror.protocol.v1.Goodbye
import io.github.anmirror.protocol.v1.GoodbyeReason
import io.github.anmirror.protocol.v1.Pong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/** In-memory [Wire]: two ends that deliver envelopes to each other synchronously. */
internal class MemoryWire private constructor() : Wire {
    private lateinit var peer: MemoryWire
    private var onEnvelope: ((Envelope) -> Unit)? = null
    private var onEnd: ((Throwable?) -> Unit)? = null
    private val pending = ArrayList<Envelope>()
    private var closed = false

    companion object {
        fun pair(): Pair<MemoryWire, MemoryWire> {
            val a = MemoryWire()
            val b = MemoryWire()
            a.peer = b
            b.peer = a
            return a to b
        }
    }

    override fun start(onEnvelope: (Envelope) -> Unit, onEnd: (Throwable?) -> Unit) {
        synchronized(this) {
            this.onEnvelope = onEnvelope
            this.onEnd = onEnd
            pending.forEach(onEnvelope)
            pending.clear()
            if (closed) onEnd(null)
        }
    }

    override suspend fun write(envelope: Envelope) {
        if (synchronized(this) { closed }) throw IOException("closed")
        peer.deliver(envelope)
    }

    private fun deliver(e: Envelope) {
        synchronized(this) {
            if (closed) return
            val sink = onEnvelope
            if (sink == null) pending += e else sink(e)
        }
    }

    override fun close() {
        if (shut()) peer.shut()
    }

    private fun shut(): Boolean = synchronized(this) {
        if (closed) return false
        closed = true
        onEnd?.invoke(null)
        true
    }
}

/** A Mac reachable through [FakeConnector]: answers hello and (optionally) pings. */
class FakeMac(val fpHex: String, private val scope: CoroutineScope, var caps: List<String> = CAPS) {
    @Volatile var answerPings = true
    @Volatile var helloVersion = 1
    @Volatile var errorOnHello: ErrorCode? = null

    /** Answer hello, then say goodbye with this reason right away (a session that dies at once). */
    @Volatile var goodbyeAfterHello: GoodbyeReason? = null

    /** Connections whose Mac side has ended (phone closed or Mac hung up). */
    @Volatile var disconnects = 0
        private set
    @Volatile var connects = 0
        private set
    val received = CopyOnWriteArrayList<Envelope>()
    @Volatile var current: ControlChannel? = null
        private set

    internal fun accept(host: String, port: Int): ControlChannel {
        val (phoneSide, macSide) = MemoryWire.pair()
        val mac = ControlChannel(macSide, host, port, Identities.PHONE_FP)
        val phone = ControlChannel(phoneSide, host, port, fpHex)
        connects++
        current = mac
        scope.launch {
            while (true) {
                val e = try {
                    mac.receive()
                } catch (t: Throwable) {
                    null
                } ?: break
                received += e
                when (e.type) {
                    MessageType.HELLO -> {
                        val error = errorOnHello
                        if (error != null) {
                            mac.send(Channel.CHANNEL_SYSTEM, MessageType.ERROR, errorOf(error))
                            mac.close()
                        } else {
                            mac.send(Channel.CHANNEL_SYSTEM, MessageType.HELLO, macHello(caps, helloVersion), e.id)
                            goodbyeAfterHello?.let { reason ->
                                mac.send(Channel.CHANNEL_SYSTEM, MessageType.GOODBYE, Goodbye.newBuilder().setReason(reason).build())
                                mac.close()
                            }
                        }
                    }
                    MessageType.PING -> if (answerPings) {
                        mac.send(Channel.CHANNEL_SYSTEM, MessageType.PONG, Pong.getDefaultInstance(), e.id)
                    }
                }
            }
            disconnects++
        }
        return phone
    }

    suspend fun goodbye(reason: GoodbyeReason) {
        val c = checkNotNull(current)
        c.send(Channel.CHANNEL_SYSTEM, MessageType.GOODBYE, Goodbye.newBuilder().setReason(reason).build())
        c.close()
    }
}

/** A [MacConnector] over [FakeMac]s keyed by "host:port". Records every dial. */
class FakeConnector(private val now: () -> Long) : MacConnector {
    val macs = ConcurrentHashMap<String, FakeMac>()
    val dials = CopyOnWriteArrayList<Pair<String, Long>>()

    /** "host:port" where the pinned Mac answers but refuses this phone's certificate at TLS. */
    val refusing: MutableSet<String> = ConcurrentHashMap.newKeySet()

    override suspend fun connect(hosts: List<String>, port: Int, pinnedFpHex: String): ControlChannel {
        var refused = false
        for (h in hosts) {
            dials += "$h:$port" to now()
            if ("$h:$port" in refusing) {
                refused = true
                continue
            }
            val mac = macs["$h:$port"]
            if (mac != null && mac.fpHex == pinnedFpHex) return mac.accept(h, port)
        }
        throw UnreachableException(hosts, refusedByPeer = refused)
    }
}
