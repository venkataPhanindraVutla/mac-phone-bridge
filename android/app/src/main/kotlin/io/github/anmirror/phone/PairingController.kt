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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed interface PairingState {
    data object Idle : PairingState

    /** The scanned (or linked) text is not a pairing code. */
    data object NotACode : PairingState

    data class Connecting(val macName: String) : PairingState

    /** Shows [code]; waits for Confirm or Cancel. */
    data class ShowCode(val macName: String, val code: String) : PairingState

    /** The user confirmed; waiting for the Mac's user. */
    data class WaitingForMac(val macName: String) : PairingState

    data class Paired(val macName: String) : PairingState

    data class Failed(val failure: PairingFailure) : PairingState
}

/**
 * Runs one pairing at a time in the app's scope, so it survives the activity being recreated.
 * On success it saves the Mac, starts the service and hands the open connection to the
 * [ConnectionManager], which says `system.hello` on it (SPEC 5.3 step 6).
 */
class PairingController(
    private val scope: CoroutineScope,
    private val client: PhonePairingClient,
    private val store: PairedMacStore,
    private val manager: ConnectionManager,
    private val onPaired: () -> Unit,
) {
    private val _state = MutableStateFlow<PairingState>(PairingState.Idle)
    val state: StateFlow<PairingState> = _state.asStateFlow()

    private var job: Job? = null
    @Volatile private var decision: CompletableDeferred<Boolean>? = null

    /** Starts pairing with the text of a scanned QR code or an `anmirror://pair` link. */
    fun pair(text: String) {
        val uri = try {
            PairingUri.parse(text.trim())
        } catch (e: PairingUriException) {
            Log.i(TAG, "pairing: not a pairing code (${e.reason})")
            _state.value = PairingState.NotACode
            return
        }
        job?.cancel()
        _state.value = PairingState.Connecting(uri.macName)
        job = scope.launch {
            val result = client.pair(uri) { code ->
                val d = CompletableDeferred<Boolean>()
                decision = d
                _state.value = PairingState.ShowCode(uri.macName, code)
                try {
                    d.await().also { if (it) _state.value = PairingState.WaitingForMac(uri.macName) }
                } finally {
                    decision = null
                }
            }
            when (result) {
                is PairingResult.Paired -> {
                    store.save(result.mac)
                    onPaired()
                    manager.adopt(result.channel)
                    Log.i(TAG, "pairing: paired")
                    _state.value = PairingState.Paired(result.mac.name)
                }
                is PairingResult.Failed -> {
                    Log.i(TAG, "pairing: failed ${result.reason}")
                    _state.value = PairingState.Failed(result.reason)
                }
            }
        }
    }

    fun confirm() {
        decision?.complete(true)
    }

    /** Declines the code, or abandons the attempt if no code is shown yet. */
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
