package io.github.anmirror.feature.mirror

import io.github.anmirror.adb.AdbClient
import io.github.anmirror.adb.AdbEndpoint
import io.github.anmirror.adb.AdbIdentity
import io.github.anmirror.adb.AdbNotPairedException
import io.github.anmirror.adb.AdbPairingException
import io.github.anmirror.adb.AdbService
import io.github.anmirror.adb.AdbServiceFinder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.ConnectException

/** What Full mode remembers between runs. Never holds the pairing code. */
interface SetupStore {
    /** This app's identity is paired with Wireless debugging. */
    var paired: Boolean

    /** The TLS port the last successful connect used; it changes whenever Wireless debugging is turned on again. */
    var lastConnectPort: Int?

    /** The last connect failed (Wireless debugging off, or its port gone): mirroring needs setup until one succeeds. */
    var lastConnectFailed: Boolean
}

/** This app's ADB identity, stored encrypted and never backed up. */
interface IdentityHolder {
    fun load(): AdbIdentity?
    fun create(): AdbIdentity
    fun delete()
}

/** Where the one-time Full mode setup stands, for the Full mode screen. */
sealed interface SetupState {
    data object Unpaired : SetupState

    /** [FullModeSetup.startPairing] is looking for the pairing port. */
    data object Looking : SetupState

    /** Waiting for the code in the notification, or pairing with it; [portKnown] says whether NSD found the port. */
    data class Pairing(val portKnown: Boolean) : SetupState
    data class PairFailed(val error: PairingError) : SetupState
    data object Connecting : SetupState
    data object Ready : SetupState
    data object ConnectFailed : SetupState
}

/**
 * The one-time setup of Full mode on the phone: pairing this app with the phone's own Wireless
 * debugging, then keeping a connection to it. [adb] gives the client for the current identity;
 * [notify] posts the pairing notification (or re-posts it, with [state] carrying the error).
 * [log] gets stages, error names and port numbers only, never the code or an address.
 */
class FullModeSetup(
    private val adb: () -> AdbClient,
    private val finder: AdbServiceFinder,
    private val store: SetupStore,
    private val identity: IdentityHolder,
    private val notify: (portKnown: Boolean) -> Unit,
    private val scope: CoroutineScope,
    private val log: (String) -> Unit = {},
) {
    private val _state = MutableStateFlow(
        when {
            !store.paired -> SetupState.Unpaired
            store.lastConnectFailed -> SetupState.ConnectFailed
            else -> SetupState.Ready
        },
    )
    val state: StateFlow<SetupState> = _state.asStateFlow()

    val paired: Boolean get() = store.paired

    /** Pairing and connecting, one at a time. */
    private val mutex = Mutex()

    /** What the last [startPairing] found; a bare code in the reply uses its port. */
    @Volatile private var pairingEndpoint: AdbEndpoint? = null

    /** The pairing port the last [startPairing] found, to prefill the in-app port field. */
    val pairingPort: Int? get() = pairingEndpoint?.port

    /** The connect port NSD found while looking for the pairing port: typing it is the commonest mistake. */
    @Volatile private var discoveredConnectPort: Int? = null

    private val searchLock = Any()
    private var search: Job? = null

    /** Creates the identity on first use, looks for the pairing port (6 s), then posts the notification. */
    fun startPairing() {
        _state.value = SetupState.Looking
        pairingEndpoint = null
        discoveredConnectPort = null
        synchronized(searchLock) {
            // The previous search goes first, so only one of them can create the identity.
            search?.cancel()
            search = scope.launch { lookForPairing() }
        }
    }

    private suspend fun lookForPairing() {
        try {
            if (identity.load() == null) {
                identity.create()
                log("identity created")
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log("identity failed class=${e.javaClass.simpleName}")
            _state.value = SetupState.Unpaired
            return
        }
        coroutineScope {
            // The connect port, alongside: a reply with it is then known to be the wrong port.
            launch {
                finder.find(AdbService.CONNECT, PAIRING_SEARCH_MS)?.let {
                    discoveredConnectPort = it.port
                    log("connect service port=${it.port}")
                }
            }
            val found = finder.find(AdbService.PAIRING, PAIRING_SEARCH_MS)
            pairingEndpoint = found
            log(if (found != null) "pairing service port=${found.port}" else "pairing service not found")
            _state.value = SetupState.Pairing(portKnown = found != null)
            notify(found != null)
        }
    }

    /** Parses the reply, pairs, then connects. Null once paired; the error otherwise (the notification is re-posted). */
    suspend fun submitReply(text: String): PairingError? = mutex.withLock {
        val found = pairingEndpoint
        val portKnown = found != null
        val reply = PairingReply.parse(text, found?.port) as? ReplyParse.Ok
        if (reply == null) {
            log("reply invalid")
            return@withLock fail(PairingError.INVALID, portKnown)
        }
        _state.value = SetupState.Pairing(portKnown)
        try {
            if (identity.load() == null) identity.create()
            pair(reply, found)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val connectPorts = listOfNotNull(store.lastConnectPort, discoveredConnectPort)
            val knownConnectPort = connectPorts.firstOrNull { it == reply.port } ?: connectPorts.firstOrNull()
            val error = PairingErrors.classify(e, reply.port, knownConnectPort)
            val staged = e as? AdbPairingException
            log("pair failed port=${reply.port} error=$error stage=${staged?.stage} hint=${staged?.hint} classes=${classes(e)}")
            return@withLock fail(error, portKnown)
        }
        store.paired = true
        log("paired port=${reply.port}")
        connectLocked(typedPort = null)
        null
    }

    /**
     * The in-app "Pairing port" and "Pairing code" fields, for when the notification can't show
     * (ruling R50): the same reply rules, pairing, errors and notify as [submitReply].
     */
    suspend fun submitInApp(port: String, code: String): PairingError? = submitReply(PairingReply.fromFields(port, code))

    /**
     * Connects unless connected: the cached port, then the port NSD finds (5 s), then [typedPort].
     * A failure sets [SetupStore.lastConnectFailed], so mirroring needs setup until one succeeds.
     */
    suspend fun ensureConnected(typedPort: Int? = null): Boolean = mutex.withLock { connectLocked(typedPort) }

    /** Deletes the identity and resets the store: Full mode must be set up again. */
    fun forget() {
        synchronized(searchLock) {
            search?.cancel()
            search = null
        }
        pairingEndpoint = null
        if (identity.load() != null) runCatching { adb().close() }
        identity.delete()
        store.paired = false
        store.lastConnectPort = null
        store.lastConnectFailed = false
        _state.value = SetupState.Unpaired
        log("forgotten")
    }

    private fun fail(error: PairingError, portKnown: Boolean): PairingError {
        _state.value = SetupState.PairFailed(error)
        notify(portKnown)
        return error
    }

    /** On loopback first, then on the address NSD gave, when loopback had nothing listening. */
    private suspend fun pair(reply: ReplyParse.Ok, found: AdbEndpoint?) {
        val client = adb()
        val hosts = listOfNotNull(LOOPBACK, found?.host?.takeIf { it != LOOPBACK })
        for ((i, host) in hosts.withIndex()) {
            try {
                client.pair(host, reply.port, reply.code)
                return
            } catch (e: Exception) {
                val refused = (e as? AdbPairingException)?.stage == AdbPairingException.Stage.NOT_LISTENING || e is ConnectException
                if (!refused || i == hosts.lastIndex) throw e
                log("pair: nothing on loopback, trying the NSD host")
            }
        }
    }

    private suspend fun connectLocked(typedPort: Int?): Boolean {
        if (!store.paired) return false
        if (identity.load() == null) {
            // The identity is gone (deleted, or its key with it): pair again.
            store.paired = false
            store.lastConnectFailed = false
            _state.value = SetupState.Unpaired
            log("connect: no identity")
            return false
        }
        val client = adb()
        if (client.isConnected) {
            succeeded(store.lastConnectPort)
            return true
        }
        _state.value = SetupState.Connecting
        val tried = mutableSetOf<Pair<String, Int>>()
        suspend fun attempt(host: String, port: Int, via: String): Boolean {
            if (port !in 1..MAX_PORT || !tried.add(host to port)) return false
            return try {
                client.connect(host, port)
                true
            } catch (e: CancellationException) {
                throw e
            } catch (e: AdbNotPairedException) {
                throw e // no other port will take this key
            } catch (e: Exception) {
                log("connect failed port=$port via=$via class=${e.javaClass.simpleName}")
                false
            }
        }
        val port = try {
            store.lastConnectPort?.takeIf { attempt(LOOPBACK, it, "cached") }
                ?: finder.find(AdbService.CONNECT, CONNECT_SEARCH_MS)?.let { ep ->
                    ep.port.takeIf { attempt(LOOPBACK, ep.port, "nsd") || attempt(ep.host, ep.port, "nsd-host") }
                }
                ?: typedPort?.takeIf { attempt(LOOPBACK, it, "typed") }
        } catch (e: AdbNotPairedException) {
            // The pairing was removed in Wireless debugging: set up again (NEEDS_SETUP, "Set up Full
            // mode"), not the re-enable loop. The identity stays; pairing it again is fine.
            store.paired = false
            store.lastConnectPort = null
            store.lastConnectFailed = false
            _state.value = SetupState.Unpaired
            log("connect: pairing revoked")
            return false
        }
        if (port == null) {
            store.lastConnectFailed = true
            _state.value = SetupState.ConnectFailed
            log("connect: no port worked")
            return false
        }
        log("connected port=$port")
        succeeded(port)
        return true
    }

    private fun succeeded(port: Int?) {
        if (port != null) store.lastConnectPort = port
        store.lastConnectFailed = false
        _state.value = SetupState.Ready
    }

    /** The exception classes down the cause chain, for the owner's check of libadb's failures. */
    private fun classes(e: Throwable): String =
        generateSequence(e) { it.cause }.take(MAX_CAUSES).joinToString("-") { it.javaClass.simpleName }

    companion object {
        const val LOOPBACK = "127.0.0.1"
        const val PAIRING_SEARCH_MS = 6_000L
        const val CONNECT_SEARCH_MS = 5_000L
        private const val MAX_PORT = 65_535
        private const val MAX_CAUSES = 8
    }
}
