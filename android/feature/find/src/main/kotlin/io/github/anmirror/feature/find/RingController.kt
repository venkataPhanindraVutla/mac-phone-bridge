package io.github.anmirror.feature.find

import android.app.NotificationManager.INTERRUPTION_FILTER_ALARMS
import android.app.NotificationManager.INTERRUPTION_FILTER_NONE
import io.github.anmirror.protocol.v1.RingState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Rings the phone at full alarm volume until [stop]. Knows nothing about the connection, so a
 * dropped connection does not stop it; [onState] is only a report (the caller may fail to send it).
 * Both calls are idempotent and safe from any thread.
 */
class RingController(
    private val audio: AlarmAudio,
    private val dnd: DndOverride,
    private val notifier: RingNotifier,
    private val store: RingSavedStore = NoRingSavedStore,
    private val onState: (RingState) -> Unit,
) {
    private val lock = Any()
    private val _ringing = MutableStateFlow(false)
    val ringing: StateFlow<Boolean> = _ringing.asStateFlow()

    private var savedVolume = 0
    private var savedFilter: Int? = null // set only when we changed the filter
    private var maySilent = false

    fun start() {
        val state = synchronized(lock) {
            if (_ringing.value) return
            savedVolume = audio.volume()
            maySilent = false
            savedFilter = null
            try {
                if (dnd.currentFilter() == INTERRUPTION_FILTER_NONE) {
                    if (dnd.hasAccess()) {
                        savedFilter = INTERRUPTION_FILTER_NONE
                        // Persist first: if the process dies, the next start puts things back.
                        store.save(SavedRingState(savedVolume, savedFilter))
                        dnd.setFilter(INTERRUPTION_FILTER_ALARMS) // alarms are allowed through
                    } else {
                        maySilent = true // Total silence blocks even alarms, and we may not change it
                    }
                }
                if (savedFilter == null) store.save(SavedRingState(savedVolume, null))
                audio.setVolume(audio.maxVolume())
                audio.startLoop()
                notifier.show()
                _ringing.value = true
            } catch (e: Exception) {
                // Half-started: put everything back and report not ringing.
                runCatching { audio.stopLoop() }
                restore()
                runCatching { notifier.cancel() }
                maySilent = false
                _ringing.value = false
            }
            current()
        }
        onState(state)
    }

    fun stop() {
        val state = synchronized(lock) {
            if (!_ringing.value) return
            audio.stopLoop()
            restore()
            maySilent = false
            notifier.cancel()
            _ringing.value = false
            current()
        }
        onState(state)
    }

    /** On service start: if a previous process died mid-ring, put the volume and filter back once. */
    fun restoreLeftover() {
        synchronized(lock) {
            if (_ringing.value) return
            val saved = store.load() ?: return
            restoreFilter(saved.filter)
            audio.setVolume(saved.volume)
            store.clear()
        }
    }

    private fun restore() {
        audio.setVolume(savedVolume)
        restoreFilter(savedFilter)
        savedFilter = null
        store.clear()
    }

    // Only if it is still our ALARMS: a change the user made meanwhile stays.
    private fun restoreFilter(filter: Int?) {
        if (filter != null && dnd.currentFilter() == INTERRUPTION_FILTER_ALARMS) dnd.setFilter(filter)
    }

    /** What the Mac should be told now. */
    fun currentState(): RingState = synchronized(lock) { current() }

    private fun current(): RingState =
        RingState.newBuilder().setRinging(_ringing.value).setMayBeSilent(maySilent).build()
}
