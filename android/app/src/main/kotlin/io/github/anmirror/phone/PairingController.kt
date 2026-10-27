package io.github.anmirror.phone

import android.util.Log
import io.github.anmirror.connection.ConnectionManager
import io.github.anmirror.connection.PairedMacStore
import io.github.anmirror.connection.PairingFailure
import io.github.anmirror.connection.PairingResult
import io.github.anmirror.connection.PhonePairingClient
import io.github.anmirror.protocol.PairingUri
import io.github.anmirror.protocol.PairingUriException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

sealed interface PairingState {
    data object Idle : PairingState

    /** The scanned (or linked) text is not a pairing code. */
    data object NotACode : PairingState

    /**
     * An `anmirror://pair` link opened the app. Nothing is dialed until the user agrees
     * ([PairingController.acceptLink]); a web page can open such a link (ruling R27).
     * [replaces] names the Mac this pairing would replace, if any.
     */
    data class LinkOffer(val uri: PairingUri, val replaces: String?) : PairingState {
        val macName: String get() = uri.macName
    }

    data class Connecting(val macName: String) : PairingState

    /** Shows [code]; waits for Confirm or Cancel. [replaces] as in [LinkOffer]. */
    data class ShowCode(val macName: String, val code: String, val replaces: String? = null) : PairingState

    /** The user confirmed; waiting for the Mac's user. */
    data class WaitingForMac(val macName: String) : PairingState

    data class Paired(val macName: String) : PairingState

    data class Failed(val failure: PairingFailure) : PairingState
}

/**
 * Runs one pairing at a time in the app's scope, so it survives the activity being recreated.
 *
 * - Only local-network hosts from the code are dialed ([LanHosts]); with none, it fails as
 *   UNREACHABLE without dialing.
 * - A link waits for consent ([offerLink], then [acceptLink]) and never interrupts a pairing.
 * - [confirm] starts the connection service, while the app is in front (Android does not let a
 *   background app start a foreground service).
 * - On success it saves the Mac, forgets the Mac it replaces, and hands the open connection to
 *   the [ConnectionManager], which says `system.hello` on it (SPEC 5.3 step 6). That runs to the
 *   end even if the user cancels late, so the connection cannot leak.
 */
class PairingController(
    private val scope: CoroutineScope,
    private val client: PhonePairingClient,
    private val store: PairedMacStore,
    private val manager: ConnectionManager,
    private val startService: () -> Unit,
) {
    private val _state = MutableStateFlow<PairingState>(PairingState.Idle)
    val state: StateFlow<PairingState> = _state.asStateFlow()

    private var job: Job? = null
    @Volatile private var decision: CompletableDeferred<Boolean>? = null

    /** A pairing is under way: connecting, showing the code, or waiting for the Mac. */
    private fun inProgress(): Boolean = when (_state.value) {
        is PairingState.Connecting, is PairingState.ShowCode, is PairingState.WaitingForMac -> true
        else -> job?.isActive == true
    }

    /** An `anmirror://pair` link: asks before dialing. Ignored while a pairing is in progress. */
    fun offerLink(text: String) {
        if (inProgress()) {
            Log.i(TAG, "pairing: link ignored, a pairing is in progress")
            return
        }
        val uri = parse(text) ?: return
        scope.launch {
            val replaces = replacedName(uri)
            if (!inProgress()) {
                Log.i(TAG, "pairing: link offered, waiting for consent")
                _state.value = PairingState.LinkOffer(uri, replaces)
            }
        }
    }

    /** The user agreed to the [PairingState.LinkOffer] on screen. */
    fun acceptLink() {
        val offer = _state.value as? PairingState.LinkOffer ?: return
        Log.i(TAG, "pairing: link accepted")
        start(offer.uri)
    }

    /** Starts pairing with the text of a scanned QR code. */
    fun pair(text: String) {
        if (inProgress()) return
        start(parse(text) ?: return)
    }

    private fun parse(text: String): PairingUri? = try {
        PairingUri.parse(text.trim())
    } catch (e: PairingUriException) {
        Log.i(TAG, "pairing: not a pairing code (${e.reason})")
        if (!inProgress()) _state.value = PairingState.NotACode
        null
    }

    private fun start(code: PairingUri) {
        val hosts = LanHosts.filter(code.hosts)
        if (hosts.size < code.hosts.size) Log.w(TAG, "pairing: dropped ${code.hosts.size - hosts.size} non-LAN host(s)")
        if (hosts.isEmpty()) {
            _state.value = PairingState.Failed(PairingFailure.UNREACHABLE)
            return
        }
        val uri = code.copy(hosts = hosts)
        Log.i(TAG, "pairing: dialing ${hosts.size} host(s)")
        _state.value = PairingState.Connecting(uri.macName)
        job = scope.launch {
            val replaces = replacedName(uri)
            val result = client.pair(uri) { code6 ->
                val d = CompletableDeferred<Boolean>()
                decision = d
                _state.value = PairingState.ShowCode(uri.macName, code6, replaces)
                try {
                    d.await().also { if (it) _state.value = PairingState.WaitingForMac(uri.macName) }
                } finally {
                    decision = null
                }
            }
            when (result) {
                is PairingResult.Paired -> withContext(NonCancellable) {
                    var saved = false
                    try {
                        store.save(result.mac)
                        saved = true
                        // One Mac at a time: the Mac this replaces is forgotten (and told, if connected).
                        store.all().filter { it.id != result.mac.id }.forEach { manager.forget(it.id) }
                        startService()
                    } catch (e: Exception) {
                        Log.e(TAG, "pairing: cannot finish", e)
                    } finally {
                        if (saved) manager.adopt(result.channel) else result.channel.close()
                    }
                    Log.i(TAG, "pairing: paired=$saved")
                    _state.value = if (saved) PairingState.Paired(result.mac.name) else PairingState.Failed(PairingFailure.REJECTED)
                }
                is PairingResult.Failed -> {
                    Log.i(TAG, "pairing: failed ${result.reason}")
                    _state.value = PairingState.Failed(result.reason)
                }
            }
        }
    }

    /** The name of the paired Mac that pairing with [uri] would replace, or null. */
    private suspend fun replacedName(uri: PairingUri): String? {
        val id = uri.macFingerprint.joinToString("") { "%02x".format(it) }
        return runCatching { store.all() }.getOrDefault(emptyList())
            .filter { it.id != id }
            .maxByOrNull { it.lastConnectedAt }?.name
    }

    /** The user confirmed the code. Also starts the service now, while the app is in front. */
    fun confirm() {
        val d = decision ?: return
        startService()
        d.complete(true)
    }

    /** Declines the code or the link, or abandons the attempt if no code is shown yet. */
    fun cancel() {
        val d = decision
        if (d != null) {
            d.complete(false)
        } else {
            job?.cancel()
            _state.value = PairingState.Idle
        }
    }

    /** Back to [PairingState.Idle] after a result was shown. */
    fun dismiss() {
        val s = _state.value
        if (s is PairingState.Paired || s is PairingState.Failed || s == PairingState.NotACode) _state.value = PairingState.Idle
    }
}
