package io.github.anmirror.connection

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.Goodbye
import io.github.anmirror.protocol.v1.GoodbyeReason
import io.github.anmirror.protocol.v1.Hello
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.yield
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.channels.Channel as KChannel

sealed interface PhoneConnectionState {
    /** No Mac is paired. */
    data object NotPaired : PhoneConnectionState

    /** No address to try yet (no last address, nothing matching in Bonjour); waiting for one. */
    data object Searching : PhoneConnectionState

    data class Connecting(val mac: PairedMac) : PhoneConnectionState

    data class Connected(val mac: PairedMac, val shared: Set<String>) : PhoneConnectionState

    data class Unreachable(val mac: PairedMac) : PhoneConnectionState

    /**
     * The Mac answered with its pinned certificate but does not know this phone: an explicit
     * `system.error NOT_PAIRED`, or a TLS refusal on any address tried (with no connection made) in 2 consecutive attempts.
     * Likely it forgot this phone while we were away. Left on [ConnectionManager.kick], on a
     * Bonjour address not tried yet, or after `notRecognizedRetryMs` (15 min). Never forgotten
     * automatically: a refusal is spoofable.
     */
    data class NotRecognized(val mac: PairedMac) : PhoneConnectionState

    /** Different protocol versions. Not retried until [ConnectionManager.kick]. */
    data class Incompatible(val mac: PairedMac) : PhoneConnectionState

    /** The Mac is serving another phone; retried after `busyRetryMs` or on kick. */
    data class Busy(val mac: PairedMac) : PhoneConnectionState

    /** [ConnectionManager.stop] was called. */
    data object Stopped : PhoneConnectionState
}

/** Timing knobs. Defaults are the SPEC 7 values plus rulings R16; tests inject their own. */
data class ConnectionTiming(
    /** The phone's own ping interval without `liveness.v1`; also how long a session must live to reset the backoff. */
    val pingIntervalMs: Long = 30_000,
    val pongTimeoutMs: Long = 10_000,
    /** With `liveness.v1`: the phone pings only after this long with nothing received. */
    val fallbackIdleMs: Long = 45_000,
    val helloTimeoutMs: Long = 10_000,
    /** Delay before retry n (0-based); the last value repeats: 1, 2, 4, 5, 5, 5, 15, 30, 30, ... s. */
    val backoffMs: List<Long> = listOf(1_000, 2_000, 4_000, 5_000, 5_000, 5_000, 15_000, 30_000),
    /** Retry delay after `system.error BUSY`. */
    val busyRetryMs: Long = 60_000,
    /** Timed retry out of `NotRecognized`. */
    val notRecognizedRetryMs: Long = 15 * 60_000,
    /** Consecutive attempts ending in a heuristic (TLS) refusal before `NotRecognized`. */
    val heuristicRefusalsForNotRecognized: Int = 2,
    /**
     * A session connected at least this long (wall time, sleep included) that the Mac closed or
     * said goodbye on is dialed again at once, inside the wake-up the FIN gave a locked phone.
     */
    val redialNowAfterMs: Long = SessionEndCode.MATURED_MS,
) {
    fun backoff(attempt: Int): Long = backoffMs[attempt.coerceIn(0, backoffMs.lastIndex)]
}

/**
 * Keeps the phone connected to its Mac (one Mac at a time, SPEC 1).
 *
 * Policy:
 * - Picks the paired Mac with the latest `lastConnectedAt`.
 * - While disconnected, keeps one Bonjour subscription for that Mac; the latest service whose
 *   TXT `r` matches its rotating ID at ±1 epoch (SPEC 6) is its discovered address.
 * - An attempt tries `lastHost:lastPort`, then the discovered address.
 * - After a failed attempt waits 1, 2, 4, 5, 5, 5 s, then 15 s once, then 30 s each time.
 *   [kick] retries now and resets that; so does a matching Bonjour event, so a Mac that wakes
 *   and re-advertises is reached within seconds even at the 30 s cap. Kicks that land
 *   together (screen on, network change, watchdog) give one retry.
 * - `BUSY`: retry after 60 s or on [kick]. Protocol mismatch: `Incompatible`, until [kick].
 * - [PhoneConnectionState.NotRecognized] at once on an explicit `system.error NOT_PAIRED`; for a
 *   TLS-level refusal (a heuristic: resets look alike) only after 2 consecutive attempts that
 *   each ended without a connection and with at least one address refused. The first such
 *   attempt backs off like `Unreachable`.
 * - After a session shorter than one ping interval, the backoff wait ignores Bonjour events:
 *   the new subscription replays the visible Mac, which must not cause a hot reconnect loop.
 * - While connected, keep-alive has two modes (SPEC 7, see [PhoneSession]):
 *   - Without `liveness.v1` shared (0.1): ping every 30 s, reconnect if no pong within 10 s.
 *   - With it, the Mac pings every 30 s and the phone answers each at once. The phone pings
 *     only after 45 s with nothing received, and reconnects if nothing arrives within 10 s.
 *   In both, a [kick] while connected pings at once, unless a ping already awaits its
 *   answer (that ping's 10 s deadline stands). Discovery is not subscribed while
 *   connected, so other paired Macs appearing change nothing.
 * - Saves `lastHost`/`lastPort`/`lastConnectedAt` on every successful connect. The backoff
 *   starts over after a session that lived at least one ping interval (awake or wall time) or
 *   answered a Mac ping.
 * - A session connected for 60 s or more ([ConnectionTiming.redialNowAfterMs]) that the Mac
 *   closed (EOF) or said goodbye on is dialed again at once, then with the backoff. A locked
 *   phone is awake only briefly after the Mac's FIN (Mac wake, Mac app restart).
 * - `system.goodbye UNPAIRED` removes the Mac, then moves on to the next Mac or `NotPaired`.
 *   This phone says goodbye UNPAIRED only for a Mac it removed itself ([forget]); a Mac that is
 *   missing from an unreadable store read is closed without a goodbye and retried.
 *   Any other goodbye (`SHUTDOWN` when the Mac app quits, ...) is a normal disconnect: the Mac
 *   stays paired and is retried with the backoff above.
 * - A store write that fails at connect is logged; the session goes on. Any other unexpected
 *   error restarts the loop after a backoff (1, 2, 4, ... s, or a kick): it never ends by itself.
 *
 * [hello] builds the phone's `system.hello`; its capabilities decide what [send] allows.
 * [clock] is unix milliseconds (rotating-ID epoch and `lastConnectedAt`). [uptimeMs] is
 * monotonic uptime for the keep-alive timers (it stops in deep sleep).
 */
class ConnectionManager(
    private val scope: CoroutineScope,
    private val store: PairedMacStore,
    private val discovery: MacDiscovery,
    private val connector: MacConnector,
    private val hello: () -> Hello,
    private val clock: () -> Long = System::currentTimeMillis,
    private val timing: ConnectionTiming = ConnectionTiming(),
    /** Where unexpected errors are reported (the app passes Android's log). */
    private val log: (String, Throwable?) -> Unit = { message, e ->
        System.err.println("ConnectionManager: $message${e?.let { ": $it" } ?: ""}")
    },
    private val uptimeMs: () -> Long = monotonicUptimeMs,
    /** Time since boot including deep sleep (the app passes `SystemClock.elapsedRealtime`). */
    private val elapsedMs: () -> Long = clock,
    /**
     * Each session that reached Connected, when it ends: a [SessionEndCode], how long it was
     * connected ([elapsedMs]) and whether it shared `liveness.v1`. Content-free; for the event log.
     */
    private val onSessionEnd: (reason: String, connectedMs: Long, liveness: Boolean) -> Unit = { _, _, _ -> },
) {
    private val _state = MutableStateFlow<PhoneConnectionState>(PhoneConnectionState.NotPaired)
    val state: StateFlow<PhoneConnectionState> = _state.asStateFlow()

    private val handlers = ConcurrentHashMap<String, suspend (Envelope) -> Unit>()

    /** [kick] from the app (network changed, Mac paired, user retry). */
    private val userKicks = KChannel<Unit>(KChannel.CONFLATED)

    /** A Bonjour event matching the target Mac arrived. */
    private val discoveryWake = KChannel<Unit>(KChannel.CONFLATED)

    /** Serialises [forget] with connection setup (presence check, save, publish). */
    private val setupLock = Mutex()

    /**
     * Lowercase ids of Macs this process removed ([forget], or the Mac's goodbye UNPAIRED). A Mac
     * missing from a store read is "forgotten" only if it is here; otherwise the store could not
     * be read just now (Keystore busy), and the Mac must not be told to forget this phone.
     */
    private val forgotten: MutableSet<String> = ConcurrentHashMap.newKeySet()

    private val stateLock = Any()
    private var job: Job? = null
    private var generation = 0

    @Volatile private var found: DiscoveredService? = null

    /** A connection handed over by [adopt], not yet used by an attempt. */
    private val adopted = AtomicReference<ControlChannel?>(null)

    private class Current(val mac: PairedMac, val session: PhoneSession) {
        /** Set by whoever ends this session for a switch (adopt or setup), so A is told once. */
        val switching = AtomicBoolean(false)
    }

    @Volatile private var current: Current? = null

    fun start() {
        synchronized(stateLock) {
            if (job?.isActive == true) return
            val gen = ++generation
            job = scope.launch { supervise(gen) }
        }
    }

    /** Stops connecting, closes the connection (no goodbye) and moves to `Stopped`. */
    fun stop() {
        synchronized(stateLock) {
            generation++ // the old loop can no longer publish states
            job?.cancel()
            job = null
            _state.value = PhoneConnectionState.Stopped
        }
        current?.session?.channel?.close()
    }

    /** The network changed (or a Mac was just paired): retry now and reset the backoff. */
    fun kick() {
        userKicks.trySend(Unit)
    }

    /**
     * Hands over the connection a finished pairing left open (SPEC 5.3 step 6: the phone says
     * `system.hello` on the same connection). Save the new Mac to the store first. The next
     * attempt for the Mac this channel is pinned to says hello on it instead of dialing; if that
     * fails it dials as usual. A channel no attempt can use is closed. A session with another
     * Mac is ended with `system.goodbye SWITCHING_MAC` (that Mac stays paired), so the new Mac
     * (the latest `lastConnectedAt`) is picked next. An attempt for another Mac that reaches
     * setup while this channel waits yields to it. Kicks.
     */
    fun adopt(channel: ControlChannel) {
        // Paired again: no longer forgotten.
        channel.peerFingerprintHex?.let { forgotten.remove(it.lowercase()) }
        adopted.getAndSet(channel)?.takeIf { it !== channel }?.close()
        // Switching Macs: tell the old one (it keeps this phone paired), then close. The loop
        // kicks again once that session has ended (the session takes kicks as pings).
        current?.takeIf { !channel.isFor(it.mac) && it.switching.compareAndSet(false, true) }?.session?.channel?.let { old ->
            scope.launch {
                try {
                    runCatching { old.send(Channel.CHANNEL_SYSTEM, MessageType.GOODBYE, goodbye(GoodbyeReason.GOODBYE_REASON_SWITCHING_MAC)) }
                } finally {
                    old.close()
                }
            }
        }
        kick()
    }

    /** For tests: a channel handed over by [adopt] is waiting. */
    internal fun hasAdoptedChannel(): Boolean = adopted.get() != null

    /**
     * Sends to the connected Mac. False when not connected or the feature is not shared.
     * [replyTo] is the id of the envelope being answered, or 0.
     */
    suspend fun send(channel: Channel, type: String, payload: MessageLite, replyTo: Long = 0): Boolean {
        val c = current ?: return false
        val feature = when (channel) {
            Channel.CHANNEL_STATUS -> "status.v1"
            Channel.CHANNEL_FIND -> "find.v1"
            else -> null
        }
        if (feature != null && feature !in c.session.shared) return false
        return try {
            c.session.channel.send(channel, type, payload, replyTo)
            true
        } catch (e: IOException) {
            false
        }
    }

    /** Handles incoming messages of [type] (one handler per type; a later call replaces it). */
    fun on(type: String, handler: suspend (Envelope) -> Unit) {
        handlers[type] = handler
    }

    /**
     * Unpairs: tells the Mac (`system.goodbye UNPAIRED`) if connected, and removes it. Returns
     * false when the store refused the removal (it could not be read just now): nothing changed,
     * the connection stays up, no goodbye is sent, and the caller says so and lets the user retry.
     */
    suspend fun forget(macId: String): Boolean {
        val c = try {
            setupLock.withLock {
                val fp = store.all().firstOrNull { it.id == macId }?.fingerprintHex ?: macId
                store.remove(macId)
                forgotten += macId.lowercase()
                // A pairing connection to this Mac waiting to be used goes too.
                adopted.get()
                    ?.takeIf { it.peerFingerprintHex.equals(fp, ignoreCase = true) && adopted.compareAndSet(it, null) }
                    ?.close()
                current?.takeIf { it.mac.id == macId }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log("could not forget the Mac", e)
            return false
        }
        if (c != null) {
            runCatching { c.session.channel.send(Channel.CHANNEL_SYSTEM, MessageType.GOODBYE, unpairedGoodbye()) }
            c.session.channel.close()
        }
        kick()
        return true
    }

    private fun setState(gen: Int, s: PhoneConnectionState) {
        synchronized(stateLock) { if (gen == generation) _state.value = s }
    }

    private sealed interface Attempt {
        data class Connected(val channel: ControlChannel, val shared: Set<String>) : Attempt
        data object NothingToDial : Attempt
        data object Unreachable : Attempt
        /** [explicit]: `system.error NOT_PAIRED`; otherwise a TLS-level (heuristic) refusal. */
        data class NotRecognized(val tried: Set<String>, val explicit: Boolean) : Attempt
        data object Busy : Attempt
        data object Incompatible : Attempt
        data object Unpaired : Attempt
    }

    /** One Bonjour subscription for the Mac being looked for (only while disconnected). */
    private inner class DiscoveryWatch(private val scope: CoroutineScope) {
        private var job: Job? = null
        private var macId: String? = null

        /** Starts watching [mac], or restarts a subscription for it that has finished. */
        fun follow(mac: PairedMac) {
            if (macId == mac.id && job?.isActive == true) return
            stop()
            macId = mac.id
            job = scope.launch {
                try {
                    discovery.services().collect { service ->
                        if (matchesMac(service, mac, Math.floorDiv(clock(), 1000L))) {
                            found = service
                            discoveryWake.trySend(Unit)
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // A failing browser ends the subscription; last addresses still work.
                }
            }
        }

        /** Watches [mac] unless already following it (a finished subscription is left alone). */
        fun target(mac: PairedMac) {
            if (macId == mac.id) return
            follow(mac)
        }

        fun stop() {
            job?.cancel()
            job = null
            macId = null
            found = null
        }
    }

    private enum class Wake { TIMEOUT, USER, DISCOVERY }

    /**
     * Runs [loop] and restarts it after an unexpected error (a store that throws, a bug), after
     * the usual backoff or a kick, so the manager never stops on its own. Cancellation ([stop],
     * the scope ending) is passed on.
     */
    private suspend fun supervise(gen: Int) {
        var failures = 0
        while (true) {
            try {
                loop(gen)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("connection loop failed; restarting", e)
                (_state.value as? PhoneConnectionState.Connected)?.let { setState(gen, PhoneConnectionState.Connecting(it.mac)) }
                val kicked = withTimeoutOrNull(timing.backoff(failures)) { userKicks.receive() } != null
                failures = if (kicked) 0 else failures + 1
            }
        }
    }

    private suspend fun loop(gen: Int) = coroutineScope {
        val watch = DiscoveryWatch(this)
        var attempt = 0
        var heuristicRefusals = 0
        var restartWatch = false
        while (true) {
            // Drain kicks before reading the store, so a forget() (or pairing) that lands after
            // the read is still pending and wakes the next wait.
            userKicks.tryReceive()
            val macs = store.all()
            // A Mac whose pairing connection is waiting (adopt) goes first; then the most recent.
            val waiting = adopted.get()?.takeIf { !it.isClosed }
            val mac = macs.firstOrNull { waiting != null && waiting.isFor(it) } ?: macs.maxByOrNull { it.lastConnectedAt }
            if (mac == null) {
                watch.stop()
                setState(gen, PhoneConnectionState.NotPaired)
                userKicks.receive()
                attempt = 0
                heuristicRefusals = 0
                continue
            }
            // A user kick also restarts a Bonjour subscription that has finished.
            if (restartWatch) watch.follow(mac) else watch.target(mac)
            restartWatch = false
            yield() // let a new subscription report what it already knows
            // Bonjour events from before this attempt are satisfied by it (found is kept).
            discoveryWake.tryReceive()

            val result = connect(gen, mac)
            if (result !is Attempt.NotRecognized || result.explicit) heuristicRefusals = 0
            var backedOff = false // this wait is a step of the 1, 2, 4, ... backoff
            val wake: Wake = when (result) {
                is Attempt.Connected -> {
                    watch.stop()
                    val ended = runConnected(gen, mac, result)
                    // adopt() ended this session for another Mac; its kick went to the session.
                    if (adopted.get() != null) kick()
                    if (ended.end == SessionEnd.UNPAIRED) removeQuietly(mac)
                    // A Mac no longer paired (goodbye UNPAIRED, forget) is not retried. One missing
                    // from an unreadable store read is kept and retried after the backoff.
                    val still = store.all().firstOrNull { it.id == mac.id }
                    if (still == null && mac.isForgotten()) {
                        attempt = 0
                        continue
                    }
                    val next = still ?: mac
                    // Only a session that lived a while proves the link is good again.
                    if (ended.matured) attempt = 0
                    setState(gen, PhoneConnectionState.Connecting(next))
                    watch.target(next)
                    if (ended.redialNow) {
                        // The Mac closed a long session (it woke, or its app restarted): dial now,
                        // inside the wake-up its FIN gave a locked phone. Then the usual backoff.
                        Wake.TIMEOUT
                    } else {
                        // After a short session the new subscription's replay must not end the wait.
                        backedOff = true
                        backoffWait(attempt, listenToDiscovery = ended.matured)
                    }
                }
                Attempt.Unpaired -> {
                    removeQuietly(mac)
                    attempt = 0
                    continue
                }
                Attempt.Incompatible -> {
                    watch.stop()
                    setState(gen, PhoneConnectionState.Incompatible(mac))
                    userKicks.receive()
                    Wake.USER
                }
                is Attempt.NotRecognized -> {
                    if (!result.explicit) heuristicRefusals++
                    if (result.explicit || heuristicRefusals >= timing.heuristicRefusalsForNotRecognized) {
                        heuristicRefusals = 0
                        setState(gen, PhoneConnectionState.NotRecognized(mac))
                        awaitNotRecognizedExit(result.tried).also { attempt = 0 }
                    } else {
                        // One TLS refusal may be a reset on a flaky network: back off as usual.
                        setState(gen, PhoneConnectionState.Unreachable(mac))
                        backedOff = true
                        backoffWait(attempt, listenToDiscovery = true)
                    }
                }
                Attempt.Busy -> {
                    // Waiting for a kick or the timed retry: no Bonjour browsing meanwhile.
                    watch.stop()
                    setState(gen, PhoneConnectionState.Busy(mac))
                    if (withTimeoutOrNull(timing.busyRetryMs) { userKicks.receive() } != null) Wake.USER else Wake.TIMEOUT
                }
                Attempt.Unreachable -> {
                    setState(gen, PhoneConnectionState.Unreachable(mac))
                    backedOff = true
                    backoffWait(attempt, listenToDiscovery = true)
                }
                Attempt.NothingToDial -> {
                    setState(gen, PhoneConnectionState.Searching)
                    backedOff = true
                    backoffWait(attempt, listenToDiscovery = true)
                }
            }
            when (wake) {
                Wake.TIMEOUT -> if (backedOff) attempt++
                Wake.USER -> {
                    attempt = 0
                    restartWatch = true
                }
                Wake.DISCOVERY -> attempt = 0
            }
        }
    }

    /**
     * Waits the backoff for [attempt]. A kick (and, if [listenToDiscovery], a matching Bonjour
     * event) ends it early; the caller then resets the backoff.
     */
    private suspend fun backoffWait(attempt: Int, listenToDiscovery: Boolean): Wake =
        withTimeoutOrNull(timing.backoff(attempt)) {
            select<Wake> {
                userKicks.onReceive { Wake.USER }
                if (listenToDiscovery) discoveryWake.onReceive { Wake.DISCOVERY }
            }
        } ?: Wake.TIMEOUT

    /** Until [kick], a Bonjour address for this Mac that this attempt did not try, or the timed retry. */
    private suspend fun awaitNotRecognizedExit(tried: Set<String>): Wake =
        withTimeoutOrNull(timing.notRecognizedRetryMs) {
            while (true) {
                val kicked = select<Boolean> {
                    userKicks.onReceive { true }
                    discoveryWake.onReceive { false }
                }
                if (kicked) return@withTimeoutOrNull Wake.USER
                val f = found
                if (f != null && "${f.host}:${f.port}" !in tried) return@withTimeoutOrNull Wake.DISCOVERY
            }
            @Suppress("UNREACHABLE_CODE")
            Wake.TIMEOUT
        } ?: Wake.TIMEOUT

    /** One attempt: an adopted pairing connection, the last address, then the discovered one. */
    private suspend fun connect(gen: Int, mac: PairedMac): Attempt {
        val tried = LinkedHashSet<String>()
        var refused = false // heuristic: TLS-level refusal
        var notPaired = false // explicit system.error NOT_PAIRED

        suspend fun helloOn(channel: ControlChannel): Attempt? =
            when (val r = exchangeHello(channel, hello(), timing.helloTimeoutMs)) {
                is HelloResult.Ok -> Attempt.Connected(channel, r.shared)
                is HelloResult.Failed -> when (r.reason) {
                    HelloFailure.BUSY -> Attempt.Busy
                    HelloFailure.PROTOCOL_MISMATCH -> Attempt.Incompatible
                    HelloFailure.UNPAIRED -> Attempt.Unpaired
                    HelloFailure.NOT_PAIRED -> {
                        notPaired = true
                        null
                    }
                    HelloFailure.TLS_REFUSED -> {
                        refused = true
                        null
                    }
                    HelloFailure.TIMED_OUT, HelloFailure.CLOSED, HelloFailure.REJECTED -> null
                }
            }

        suspend fun tryAt(host: String, port: Int): Attempt? {
            if (!tried.add("$host:$port")) return null
            setState(gen, PhoneConnectionState.Connecting(mac))
            val channel = try {
                connector.connect(listOf(host), port, mac.fingerprintHex)
            } catch (e: UnreachableException) {
                if (e.refusedByPeer) refused = true
                return null
            }
            return helloOn(channel)
        }

        // The connection a pairing just left open, if it is this Mac's.
        adopted.getAndSet(null)?.let { channel ->
            when {
                channel.isClosed -> Unit
                // Another stored Mac's (a store read from before it was saved): keep it for its
                // attempt. A channel whose Mac is not paired (any more) is closed.
                !channel.isFor(mac) ->
                    if (store.all().none { channel.isFor(it) } || !adopted.compareAndSet(null, channel)) channel.close()
                else -> {
                    tried.add("${channel.host}:${channel.port}")
                    setState(gen, PhoneConnectionState.Connecting(mac))
                    helloOn(channel)?.let { return it }
                }
            }
        }

        val host = mac.lastHost
        val port = mac.lastPort
        if (host != null && port != null) tryAt(host, port)?.let { return it }
        found?.let { s -> tryAt(s.host, s.port)?.let { return it } }
        return when {
            notPaired -> Attempt.NotRecognized(tried, explicit = true)
            refused -> Attempt.NotRecognized(tried, explicit = false)
            tried.isEmpty() -> Attempt.NothingToDial
            else -> Attempt.Unreachable
        }
    }

    /** A failed write (the store was unreadable and was left alone) is not fatal: it is retried on the next goodbye or connect. */
    private suspend fun removeQuietly(mac: PairedMac) {
        forgotten += mac.id.lowercase()
        runCatching { store.remove(mac.id) }.onFailure { e ->
            if (e is CancellationException) throw e
            log("could not remove the Mac", e)
        }
    }

    private fun PairedMac.isForgotten(): Boolean = id.lowercase() in forgotten

    /**
     * How a connection ended. [matured]: it lived one ping interval, or answered a Mac ping.
     * [redialNow]: the Mac closed it (EOF or goodbye) after [ConnectionTiming.redialNowAfterMs].
     */
    private class Ended(val end: SessionEnd, val matured: Boolean = false, val redialNow: Boolean = false)

    private suspend fun runConnected(gen: Int, mac: PairedMac, a: Attempt.Connected): Ended {
        val channel = a.channel
        try {
            val session = setupLock.withLock {
                val stored = store.all()
                // Forgotten while we were dialing: do not bring it back. Missing but not
                // forgotten: the read failed (an unreadable store reads as none).
                if (stored.none { it.id == mac.id }) return@withLock if (mac.isForgotten()) FORGOTTEN else UNREADABLE
                // A just-paired Mac's connection is waiting (this attempt read the store before it
                // was saved): yield to it. No save, no session, no goodbye; the loop picks it next.
                val waiting = adopted.get()
                if (waiting != null && !waiting.isClosed && !waiting.isFor(mac) && stored.any { waiting.isFor(it) }) {
                    return@withLock YIELD
                }
                val updated = mac.copy(lastHost = channel.host, lastPort = channel.port, lastConnectedAt = clock())
                // A failed write (Keystore trouble) only loses the remembered address: go on.
                runCatching { store.save(updated) }.onFailure { e ->
                    if (e is CancellationException) throw e
                    log("could not save the Mac's address", e)
                }
                // A pairing connection to this Mac handed over while we dialed it is not needed now.
                adopted.get()?.takeIf { it !== channel && it.isFor(mac) && adopted.compareAndSet(it, null) }?.close()
                val session = PhoneSession(
                    channel, a.shared, timing.pingIntervalMs, timing.pongTimeoutMs, timing.fallbackIdleMs, uptimeMs,
                )
                val cur = Current(updated, session)
                current = cur
                // adopt() sets `adopted` before reading `current`; we publish `current`, then read
                // `adopted`. So an adopt() that ran during this setup (and saw no current) is seen
                // here: hand over to the adopted Mac instead of starting this session.
                val late = adopted.get()
                if (late != null && !late.isClosed && !late.isFor(mac) && store.all().any { late.isFor(it) }) {
                    return@withLock if (cur.switching.compareAndSet(false, true)) SWITCH else HANDLED
                }
                setState(gen, PhoneConnectionState.Connected(updated, a.shared))
                session
            }
            if (session === YIELD || session === UNREADABLE) {
                // No goodbye: an unreadable store must never make the Mac forget this phone.
                channel.close()
                return Ended(SessionEnd.CLOSED)
            }
            if (session === SWITCH) {
                runCatching { channel.send(Channel.CHANNEL_SYSTEM, MessageType.GOODBYE, goodbye(GoodbyeReason.GOODBYE_REASON_SWITCHING_MAC)) }
                channel.close()
                return Ended(SessionEnd.CLOSED)
            }
            if (session === HANDLED) {
                // adopt() saw this session too; it sends the goodbye, then closes the channel.
                return Ended(SessionEnd.CLOSED)
            }
            if (session !is PhoneSession) {
                // FORGOTTEN
                runCatching { channel.send(Channel.CHANNEL_SYSTEM, MessageType.GOODBYE, unpairedGoodbye()) }
                channel.close()
                return Ended(SessionEnd.CLOSED)
            }
            val liveness = LIVENESS_CAPABILITY in a.shared
            val connectedAt = elapsedMs()
            fun report() = runCatching {
                onSessionEnd(session.endCode ?: SessionEndCode.CANCELLED, elapsedMs() - connectedAt, liveness)
            }
            return try {
                coroutineScope {
                    val matured = AtomicBoolean(false)
                    // Awake time: a locked phone's delay barely runs, so wall time and an answered
                    // Mac ping count too.
                    val timer = launch {
                        delay(timing.pingIntervalMs)
                        matured.set(true)
                    }
                    val end = session.run(pingNow = userKicks, onMacPing = { matured.set(true) }) { env ->
                        handlers[env.type]?.invoke(env)
                    }
                    timer.cancel()
                    val connectedMs = elapsedMs() - connectedAt
                    val code = session.endCode
                    val closedByMac = code == SessionEndCode.EOF || end == SessionEnd.GOODBYE
                    Ended(
                        end,
                        matured = matured.get() || connectedMs >= timing.pingIntervalMs,
                        redialNow = closedByMac && connectedMs >= timing.redialNowAfterMs,
                    )
                }
            } finally {
                report()
            }
        } catch (t: Throwable) {
            channel.close()
            throw t
        } finally {
            current = null
        }
    }

    private fun ControlChannel.isFor(mac: PairedMac): Boolean =
        peerFingerprintHex.equals(mac.fingerprintHex, ignoreCase = true)

    private fun unpairedGoodbye(): Goodbye = goodbye(GoodbyeReason.GOODBYE_REASON_UNPAIRED)

    private fun goodbye(reason: GoodbyeReason): Goodbye = Goodbye.newBuilder().setReason(reason).build()

    private companion object {
        /** runConnected's setup results: yield to an adopted channel of another Mac (before any
         *  save), or end this just-set-up session for it with SWITCHING_MAC (adopt raced setup);
         *  HANDLED when adopt() is already sending that goodbye. */
        val YIELD = Any()
        val SWITCH = Any()
        val HANDLED = Any()

        /** The Mac is missing from the store read: [FORGOTTEN] by this process (goodbye UNPAIRED), or the read failed. */
        val FORGOTTEN = Any()
        val UNREADABLE = Any()
    }
}
