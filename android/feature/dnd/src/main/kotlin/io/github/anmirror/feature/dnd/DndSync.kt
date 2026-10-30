package io.github.anmirror.feature.dnd

import android.app.NotificationManager.INTERRUPTION_FILTER_ALL
import android.app.NotificationManager.INTERRUPTION_FILTER_PRIORITY
import com.google.protobuf.MessageLite
import io.github.anmirror.feature.find.DndOverride
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.DndAvailability
import io.github.anmirror.protocol.v1.DndOrigin
import io.github.anmirror.protocol.v1.DndState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The phone's side of Do Not Disturb sync (F-11, SPEC 21). Knows nothing about the connection or
 * the switch: the caller starts it while the feature is open ([onConnected]), feeds it the filter
 * broadcasts ([onLocalChange]) and the Mac's messages, and [send] gates what goes out.
 *
 * "On" is any filter but ALL ([DndRules]), read as the global state. On Android 15+ (targetSdk 35+)
 * [DndOverride.setFilter] turns on this app's implicit mode rather than the global zen; the global
 * filter then still reads PRIORITY, and its broadcast comes back here as the echo. Turning the
 * mode off leaves a Do Not Disturb the user set themselves on: the phone then stays on.
 *
 * Safe from any thread: the state is kept under a lock, and sends are serialized in call order.
 */
class DndSync(
    private val dnd: DndOverride,
    private val send: suspend (String, MessageLite) -> Boolean,
    private val clock: () -> Long,
    private val guard: EchoGuard = EchoGuard(),
) {
    private val lock = Any()
    private val sending = Mutex()

    /** The phone's state as last seen; null until read (or while the filter is unknown). */
    private var lastSeen: Boolean? = null

    private val _macOn = MutableStateFlow<Boolean?>(null)

    /** The Mac's Focus as it last said (snapshots included); null until it does, and after a disconnect. */
    val macOn: StateFlow<Boolean?> = _macOn.asStateFlow()

    private val _macAvailability = MutableStateFlow<DndAvailability?>(null)

    /** The Mac's last `dnd.availability`; null until it sends one, and after a disconnect. */
    val macAvailability: StateFlow<DndAvailability?> = _macAvailability.asStateFlow()

    /**
     * The feature opened (on connect, or the switch turned on): the current filter becomes the
     * baseline, so a change while closed is not a transition. When [sends], it goes to the Mac as
     * the snapshot (shown there, never applied).
     */
    suspend fun onConnected(sends: Boolean) {
        sending.withLock {
            val on = synchronized(lock) {
                DndRules.isOn(dnd.currentFilter()).also { lastSeen = it }
            }
            if (sends && on != null) send(MessageType.DND_STATE, state(on, DndOrigin.DND_ORIGIN_USER, snapshot = true))
        }
    }

    /**
     * The interruption filter changed (or may have): a transition is classified against the last
     * applied Mac state and, unless it is that state's echo, sent while the Mac's `applies` is
     * enabled (nil = off). An unknown filter, or a change between two "on" filters, is no transition.
     */
    suspend fun onLocalChange() {
        sending.withLock {
            val out = synchronized(lock) {
                val on = DndRules.isOn(dnd.currentFilter()) ?: return
                if (on == lastSeen) return
                val first = lastSeen == null
                lastSeen = on
                if (first) return // the baseline, not a transition
                val origin = when (guard.classify(on, clock())) {
                    Echo.SUPPRESS -> return
                    Echo.SYNC -> DndOrigin.DND_ORIGIN_SYNC
                    Echo.USER -> DndOrigin.DND_ORIGIN_USER
                }
                if (_macAvailability.value?.applies?.enabled != true) return
                state(on, origin, snapshot = false)
            }
            send(MessageType.DND_STATE, out)
        }
    }

    /**
     * The Mac's Focus: always shown ([macOn]); applied only when it is a transition the Mac's user
     * made, this app has Do Not Disturb access, and the phone is not in that state already.
     */
    fun onMacState(s: DndState) {
        synchronized(lock) {
            _macOn.value = s.on
            if (s.snapshot || s.origin != DndOrigin.DND_ORIGIN_USER || !dnd.hasAccess()) return
            val mine = DndRules.isOn(dnd.currentFilter()) ?: return
            if (mine == s.on) return
            dnd.setFilter(if (s.on) INTERRUPTION_FILTER_PRIORITY else INTERRUPTION_FILTER_ALL)
            guard.applied(s.on, clock())
        }
    }

    fun onMacAvailability(a: DndAvailability) {
        _macAvailability.value = a
    }

    /** The session ended: what the Mac said goes with it. The echo guard stays (a late broadcast is still an echo). */
    fun onDisconnected() {
        synchronized(lock) {
            lastSeen = null
            _macOn.value = null
            _macAvailability.value = null
        }
    }

    private fun state(on: Boolean, origin: DndOrigin, snapshot: Boolean): DndState =
        DndState.newBuilder().setOn(on).setOrigin(origin).setSnapshot(snapshot).build()
}
