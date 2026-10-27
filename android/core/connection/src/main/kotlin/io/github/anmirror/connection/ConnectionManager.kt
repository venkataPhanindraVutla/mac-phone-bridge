package io.github.anmirror.connection

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.Goodbye
import io.github.anmirror.protocol.v1.GoodbyeReason
import io.github.anmirror.protocol.v1.Hello
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.channels.Channel as KChannel

sealed interface PhoneConnectionState {
    /** No Mac is paired. */
    data object NotPaired : PhoneConnectionState

    /** The last address failed; waiting for the Mac to show up in Bonjour. */
    data object Searching : PhoneConnectionState

    data class Connecting(val mac: PairedMac) : PhoneConnectionState

    data class Connected(val mac: PairedMac, val shared: Set<String>) : PhoneConnectionState

    data class Unreachable(val mac: PairedMac) : PhoneConnectionState

    /** Different protocol versions. Not retried until [ConnectionManager.kick]. */
    data class Incompatible(val mac: PairedMac) : PhoneConnectionState

    /** The Mac is serving another phone; retried with backoff. */
    data class Busy(val mac: PairedMac) : PhoneConnectionState
}

/** Timing knobs. Defaults are the SPEC 5.2/7 values; tests inject short ones. */
data class ConnectionTiming(
    val pingIntervalMs: Long = 30_000,
    val pongTimeoutMs: Long = 10_000,
    val helloTimeoutMs: Long = 10_000,
    /** How long to wait for a matching Bonjour service in one attempt. */
    val discoveryTimeoutMs: Long = 10_000,
    /** Delay before retry n (0-based); the last value repeats: 1, 2, 4, 5, 5, ... s. */
    val backoffMs: List<Long> = listOf(1_000, 2_000, 4_000, 5_000),
) {
    fun backoff(attempt: Int): Long = backoffMs[attempt.coerceIn(0, backoffMs.lastIndex)]
}

/**
 * Keeps the phone connected to its Mac (one Mac at a time, SPEC 1).
 *
 * Policy:
 * - Picks the paired Mac with the latest `lastConnectedAt`.
 * - Tries `lastHost:lastPort` first; otherwise waits (up to `discoveryTimeoutMs`) for a
 *   Bonjour service whose TXT `r` matches that Mac's rotating ID at ±1 epoch (SPEC 6).
 * - Between failed attempts waits 1, 2, 4, 5, 5, ... s; [kick] retries now and resets it.
 * - While connected: ping every 30 s, reconnect if no pong within 10 s. Discovery is not
 *   consulted while connected, so other paired Macs appearing change nothing.
 * - Saves `lastHost`/`lastPort`/`lastConnectedAt` on every successful connect.
 * - `system.goodbye UNPAIRED` removes the Mac, then moves on to the next Mac or `NotPaired`.
 *
 * [hello] builds the phone's `system.hello`; its capabilities decide what [send] allows.
 * [clock] is unix milliseconds (rotating-ID epoch and `lastConnectedAt`).
 */
class ConnectionManager(
    private val scope: CoroutineScope,
    private val store: PairedMacStore,
    private val discovery: MacDiscovery,
    private val connector: MacConnector,
    private val hello: () -> Hello,
    private val clock: () -> Long = System::currentTimeMillis,
    private val timing: ConnectionTiming = ConnectionTiming(),
) {
    private val _state = MutableStateFlow<PhoneConnectionState>(PhoneConnectionState.NotPaired)
    val state: StateFlow<PhoneConnectionState> = _state.asStateFlow()

    private val handlers = ConcurrentHashMap<String, suspend (Envelope) -> Unit>()
    private val kicks = KChannel<Unit>(KChannel.CONFLATED)
    private var job: Job? = null

    private class Current(val mac: PairedMac, val session: PhoneSession)

    @Volatile private var current: Current? = null

    fun start() {
        synchronized(this) {
            if (job?.isActive == true) return
            job = scope.launch { loop() }
        }
    }

    /** Stops connecting and closes the connection (no goodbye). */
    fun stop() {
        synchronized(this) {
            job?.cancel()
            job = null
        }
        current?.session?.channel?.close()
    }

    /** The network changed (or a Mac was just paired): retry now and reset the backoff. */
    fun kick() {
        kicks.trySend(Unit)
    }

    /** Sends to the connected Mac. False when not connected or the feature is not shared. */
    suspend fun send(channel: Channel, type: String, payload: MessageLite): Boolean {
        val c = current ?: return false
        val feature = when (channel) {
            Channel.CHANNEL_STATUS -> "status.v1"
            Channel.CHANNEL_FIND -> "find.v1"
            else -> null
        }
        if (feature != null && feature !in c.session.shared) return false
        return try {
            c.session.channel.send(channel, type, payload)
            true
        } catch (e: IOException) {
            false
        }
    }

    /** Handles incoming messages of [type] (one handler per type; a later call replaces it). */
    fun on(type: String, handler: suspend (Envelope) -> Unit) {
        handlers[type] = handler
    }

    /** Unpairs: tells the Mac (`system.goodbye UNPAIRED`) if connected, and removes it. */
    suspend fun forget(macId: String) {
        store.remove(macId)
        val c = current
        if (c != null && c.mac.id == macId) {
            runCatching {
                c.session.channel.send(
                    Channel.CHANNEL_SYSTEM, MessageType.GOODBYE,
                    Goodbye.newBuilder().setReason(GoodbyeReason.GOODBYE_REASON_UNPAIRED).build(),
                )
            }
            c.session.channel.close()
        }
        kick()
    }

    private sealed interface Attempt {
        data class Connected(val channel: ControlChannel, val shared: Set<String>) : Attempt
        data object Unreachable : Attempt
        data object Busy : Attempt
        data object Incompatible : Attempt
        data object Unpaired : Attempt
    }

    private suspend fun loop() {
        var attempt = 0
        while (true) {
            val mac = store.all().maxByOrNull { it.lastConnectedAt }
            if (mac == null) {
                _state.value = PhoneConnectionState.NotPaired
                kicks.receive()
                attempt = 0
                continue
            }
            when (val result = connect(mac)) {
                is Attempt.Connected -> {
                    if (runConnected(mac, result) == SessionEnd.UNPAIRED) store.remove(mac.id)
                    // Dropped after being connected: start the backoff over. A Mac that is no
                    // longer paired (goodbye UNPAIRED, forget) is not retried.
                    attempt = 0
                    val still = store.all().firstOrNull { it.id == mac.id } ?: continue
                    _state.value = PhoneConnectionState.Connecting(still)
                }
                Attempt.Unpaired -> {
                    store.remove(mac.id)
                    attempt = 0
                    continue
                }
                Attempt.Incompatible -> {
                    _state.value = PhoneConnectionState.Incompatible(mac)
                    kicks.receive()
                    attempt = 0
                    continue
                }
                Attempt.Busy -> _state.value = PhoneConnectionState.Busy(mac)
                Attempt.Unreachable -> _state.value = PhoneConnectionState.Unreachable(mac)
            }
            val kicked = withTimeoutOrNull(timing.backoff(attempt)) { kicks.receive() } != null
            attempt = if (kicked) 0 else attempt + 1
        }
    }

    /** One attempt: the last address, then Bonjour. */
    private suspend fun connect(mac: PairedMac): Attempt {
        val host = mac.lastHost
        val port = mac.lastPort
        if (host != null && port != null) {
            _state.value = PhoneConnectionState.Connecting(mac)
            dial(mac, host, port)?.let { return handshake(it) }
        }
        _state.value = PhoneConnectionState.Searching
        val channel = withTimeoutOrNull(timing.discoveryTimeoutMs) {
            discovery.services()
                .filter { matchesMac(it, mac, Math.floorDiv(clock(), 1000L)) }
                .mapNotNull { service ->
                    _state.value = PhoneConnectionState.Connecting(mac)
                    dial(mac, service.host, service.port)
                        .also { if (it == null) _state.value = PhoneConnectionState.Searching }
                }
                .firstOrNull()
        } ?: return Attempt.Unreachable
        return handshake(channel)
    }

    private suspend fun dial(mac: PairedMac, host: String, port: Int): ControlChannel? = try {
        connector.connect(listOf(host), port, mac.fingerprintHex)
    } catch (e: UnreachableException) {
        null
    }

    private suspend fun handshake(channel: ControlChannel): Attempt =
        when (val r = exchangeHello(channel, hello(), timing.helloTimeoutMs)) {
            is HelloResult.Ok -> Attempt.Connected(channel, r.shared)
            is HelloResult.Failed -> when (r.reason) {
                HelloFailure.BUSY -> Attempt.Busy
                HelloFailure.PROTOCOL_MISMATCH -> Attempt.Incompatible
                HelloFailure.UNPAIRED -> Attempt.Unpaired
                // NOT_PAIRED is not taken as proof of unpairing: a TLS refusal looks the same.
                HelloFailure.NOT_PAIRED, HelloFailure.TIMED_OUT, HelloFailure.CLOSED, HelloFailure.REJECTED ->
                    Attempt.Unreachable
            }
        }

    private suspend fun runConnected(mac: PairedMac, a: Attempt.Connected): SessionEnd {
        // Forgotten while we were dialing: do not bring it back.
        if (store.all().none { it.id == mac.id }) {
            runCatching {
                a.channel.send(
                    Channel.CHANNEL_SYSTEM, MessageType.GOODBYE,
                    Goodbye.newBuilder().setReason(GoodbyeReason.GOODBYE_REASON_UNPAIRED).build(),
                )
            }
            a.channel.close()
            return SessionEnd.CLOSED
        }
        val updated = mac.copy(lastHost = a.channel.host, lastPort = a.channel.port, lastConnectedAt = clock())
        store.save(updated)
        val session = PhoneSession(a.channel, a.shared, timing.pingIntervalMs, timing.pongTimeoutMs)
        // A kick from before this connection is stale.
        kicks.tryReceive()
        current = Current(updated, session)
        _state.value = PhoneConnectionState.Connected(updated, a.shared)
        return try {
            session.run(pingNow = kicks) { env -> handlers[env.type]?.invoke(env) }
        } finally {
            current = null
        }
    }
}
