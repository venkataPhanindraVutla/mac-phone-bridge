package io.github.anmirror.phone.service

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PhoneConnectionState
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.MainActivity
import io.github.anmirror.phone.PairingState
import io.github.anmirror.phone.R
import io.github.anmirror.phone.TAG
import io.github.anmirror.phone.answerInvoke
import io.github.anmirror.phone.featureAvailability
import io.github.anmirror.phone.copyNamesMac
import io.github.anmirror.phone.macOrNull
import io.github.anmirror.phone.messageRes
import io.github.anmirror.phone.platform.NetworkWatcher
import io.github.anmirror.connection.PhoneConnectionState.Connected
import io.github.anmirror.feature.find.AndroidAlarmAudio
import io.github.anmirror.feature.find.AndroidDndOverride
import io.github.anmirror.feature.find.AndroidRingNotifier
import io.github.anmirror.feature.find.PrefsRingSavedStore
import io.github.anmirror.feature.find.RingController
import io.github.anmirror.feature.status.AndroidStatusSource
import io.github.anmirror.feature.status.StatusPublisher
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.DismissNotification
import io.github.anmirror.protocol.v1.IconRequest
import io.github.anmirror.protocol.v1.InvokeAction
import io.github.anmirror.protocol.v1.NotificationFilter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/**
 * Keeps the phone connected to its Mac: a `connectedDevice` foreground service that runs the
 * [io.github.anmirror.connection.ConnectionManager] and kicks it on network changes. Sticky, and
 * started at boot when a Mac is paired. Stops itself once no Mac is paired.
 */
class ConnectionService : LifecycleService() {
    private lateinit var graph: AppGraph
    private lateinit var network: NetworkWatcher
    private var lastText: String? = null
    private lateinit var ring: RingController
    private var lastNotifyEnabled: Boolean? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        graph = AppGraph.get(this)
        createChannel()
        goForeground(getString(R.string.state_looking_unnamed))
        network = NetworkWatcher(this) { graph.manager.kick() }
        network.start()
        graph.manager.start()
        // Phone status goes out only while the Mac shares status.v1.
        StatusPublisher(
            source = AndroidStatusSource(this),
            connected = graph.manager.state.map { it is Connected && "status.v1" in it.shared },
            send = { graph.manager.send(Channel.CHANNEL_STATUS, MessageType.STATUS_UPDATE, it) },
        ).launchIn(lifecycleScope)
        setUpFindMyPhone()
        setUpNotifications()
        lifecycleScope.launch {
            combine(graph.manager.state, graph.store.macs, graph.pairing.state) { state, macs, pairing ->
                Triple(state, macs, pairing.isUnderWay())
            }
                .distinctUntilChanged()
                .collect { (state, macs, pairing) -> onState(state, macs, pairing) }
        }
        Log.i(TAG, "service: created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent?.action == ACTION_STOP_RING && ::ring.isInitialized) ring.stop() // the Stop action / tap on the ring notification
        // Every start must be followed by startForeground, also a sticky restart.
        goForeground(lastText ?: getString(R.string.state_looking_unnamed))
        Log.i(TAG, "service: start (restart=${intent == null})")
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        _ringing.value = false
        if (::ring.isInitialized) ring.stop() // the service going away must not leave an alarm behind
        network.stop()
        graph.manager.stop()
        Log.i(TAG, "service: destroyed")
        super.onDestroy()
    }

    /**
     * The ring lives here, not in the connection: a dropped connection does not stop it. It stops
     * on find.stop, on the notification's Stop, or when this service is destroyed.
     */
    private fun setUpFindMyPhone() {
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, ConnectionService::class.java).setAction(ACTION_STOP_RING),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        ring = RingController(
            audio = AndroidAlarmAudio(this),
            dnd = AndroidDndOverride(this),
            notifier = AndroidRingNotifier(this, stop),
            store = PrefsRingSavedStore(this),
            onState = { state ->
                lifecycleScope.launch { graph.manager.send(Channel.CHANNEL_FIND, MessageType.FIND_STATE, state) }
            },
        )
        // A previous process may have died mid-ring, leaving max volume / ALARMS behind.
        ring.restoreLeftover()
        lifecycleScope.launch { ring.ringing.collect { _ringing.value = it } }
        graph.manager.on(MessageType.FIND_RING) { ring.start() }
        graph.manager.on(MessageType.FIND_STOP) { ring.stop() }
        // After a reconnect the Mac does not know the phone is still ringing: tell it.
        lifecycleScope.launch {
            graph.manager.state
                .map { it is Connected && "find.v1" in it.shared }
                .distinctUntilChanged()
                .collect { shared -> if (shared && ring.ringing.value) graph.manager.send(Channel.CHANNEL_FIND, MessageType.FIND_STATE, ring.currentState()) }
        }
    }

    /**
     * Notifications: every handler only queues onto the graph's ordered event channel, so the
     * bridge sees the listener's events and the Mac's messages in one order. Nothing is sent
     * unless [AppGraph.notifyOpen]; `notify.availability` is the one message that is, since it is
     * how the Mac learns the feature is off.
     */
    private fun setUpNotifications() {
        val bridge = graph.notifyBridge
        graph.manager.on(MessageType.NOTIFY_FILTER) { env ->
            val filter = NotificationFilter.parseFrom(env.payload)
            graph.postNotifyEvent {
                bridge.onFilter(filter)
                // The Mac sends a filter right after connecting (SPEC 10): the first one starts the session.
                graph.notifySession.filterApplied(graph.listenerBound.value)
            }
        }
        graph.manager.on(MessageType.NOTIFY_DISMISS) { env ->
            val dismiss = DismissNotification.parseFrom(env.payload)
            graph.postNotifyEvent { if (graph.notifyOpen()) bridge.onDismiss(dismiss) }
        }
        graph.manager.on(MessageType.NOTIFY_ICON_REQUEST) { env ->
            val request = IconRequest.parseFrom(env.payload)
            graph.postNotifyEvent { if (graph.notifyOpen()) bridge.onIconRequest(request) }
        }
        graph.manager.on(MessageType.NOTIFY_INVOKE) { env ->
            val invoke = InvokeAction.parseFrom(env.payload)
            graph.postNotifyEvent {
                // Exactly one result per invoke, answering this envelope; FAILED while the feature is closed.
                val result = answerInvoke(invoke.key, graph.notifyShared(), graph.notifyOpen()) { bridge.onInvoke(env.id, invoke) }
                if (result != null) graph.manager.send(Channel.CHANNEL_NOTIFY, MessageType.NOTIFY_RESULT, result, env.id)
            }
        }
        // The listener binding mid-session (boot, restart, access re-granted): catch the Mac up.
        lifecycleScope.launch {
            graph.listenerBound.collect { bound ->
                if (bound) graph.postNotifyEvent { graph.notifySession.listenerBound() }
            }
        }
        lifecycleScope.launch {
            combine(
                graph.manager.state.map { it is Connected && "notify.v1" in it.shared }.distinctUntilChanged(),
                graph.notifyOn,
                graph.notifyAccess,
            ) { connected, on, access -> Triple(connected, on, access) }
                .distinctUntilChanged()
                .collect { (connected, on, access) ->
                    if (!connected) {
                        lastNotifyEnabled = null
                        graph.postNotifyEvent {
                            graph.notifySession.reset()
                            bridge.onDisconnected()
                        }
                        return@collect
                    }
                    val availability = featureAvailability(granted = access, userOn = on)
                    if (lastNotifyEnabled == null) graph.postNotifyEvent { graph.notifySession.reset() }
                    graph.manager.send(Channel.CHANNEL_NOTIFY, MessageType.NOTIFY_AVAILABILITY, availability)
                    // Switched on (or access granted) mid-session: catch the Mac up.
                    if (availability.enabled && lastNotifyEnabled == false) {
                        graph.postNotifyEvent { graph.notifySession.enabled(graph.listenerBound.value) }
                    }
                    lastNotifyEnabled = availability.enabled
                }
        }
    }

    private fun onState(state: PhoneConnectionState, macs: List<PairedMac>?, pairing: Boolean) {
        Log.i(TAG, "state: ${state.describe()}")
        if (state == PhoneConnectionState.NotPaired) {
            // Started at Confirm, before the pairing saves the Mac: wait for it to finish.
            if (pairing) return
            // The manager starts in NotPaired before it reads the store; only stop once the store
            // agrees no Mac is paired.
            lifecycleScope.launch {
                if (graph.store.all().isEmpty()) {
                    Log.i(TAG, "service: no Mac paired, stopping")
                    ServiceCompat.stopForeground(this@ConnectionService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
            return
        }
        if (state == PhoneConnectionState.Stopped) return
        val name = state.macOrNull?.name ?: macs?.maxByOrNull { it.lastConnectedAt }?.name
        val text = when {
            state.copyNamesMac() && name != null -> getString(state.messageRes(), name)
            state.copyNamesMac() -> getString(R.string.state_looking_unnamed)
            // Unreachable is still looking; the notification stays short.
            state is PhoneConnectionState.Unreachable && name != null -> getString(R.string.state_looking, name)
            else -> getString(state.messageRes())
        }
        if (text != lastText) {
            lastText = text
            update(text)
        }
    }

    private fun createChannel() {
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
            .setName(getString(R.string.channel_connection))
            .setDescription(getString(R.string.channel_connection_description))
            .setShowBadge(false)
            .build()
        NotificationManagerCompat.from(this).createNotificationChannel(channel)
    }

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun goForeground(text: String) {
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(text), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    private fun update(text: String) {
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (allowed) NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification(text))
    }

    companion object {
        const val CHANNEL_ID = "connection"
        const val ACTION_STOP_RING = "io.github.anmirror.phone.STOP_RING"

        private val _ringing = MutableStateFlow(false)

        /** True while the phone is ringing for find-my-phone; the UI shows a Stop button then. */
        val ringing: StateFlow<Boolean> = _ringing.asStateFlow()

        /** Stops a ring in progress (no-op when the service is not running). */
        fun stopRing(context: Context) {
            if (!running) return
            try {
                context.startService(Intent(context, ConnectionService::class.java).setAction(ACTION_STOP_RING))
            } catch (e: IllegalStateException) {
                Log.w(TAG, "service: stop-ring refused (${e.javaClass.simpleName})")
            }
        }
        private const val NOTIFICATION_ID = 1

        /** True between onCreate and onDestroy. */
        @Volatile var running = false
            private set

        /**
         * Starts the service. Android refuses a foreground service started from the background
         * (ForegroundServiceStartNotAllowedException, an IllegalStateException): that is logged,
         * and MainActivity starts it on its next resume. Returns whether the start was accepted.
         */
        fun start(context: Context): Boolean = try {
            ContextCompat.startForegroundService(context, Intent(context, ConnectionService::class.java))
            true
        } catch (e: IllegalStateException) {
            Log.w(TAG, "service: start refused (${e.javaClass.simpleName})")
            false
        } catch (e: SecurityException) {
            Log.w(TAG, "service: start refused (${e.javaClass.simpleName})")
            false
        }
    }
}

/** Pairing is between Continue/scan and its result: the service must not stop meanwhile. */
private fun PairingState.isUnderWay(): Boolean =
    this is PairingState.Connecting || this is PairingState.ShowCode || this is PairingState.WaitingForMac

/** For logs: no discovery key, no addresses. */
private fun PhoneConnectionState.describe(): String = when (this) {
    is PhoneConnectionState.Connected -> "Connected(shared=${shared.sorted().joinToString(",")})"
    else -> this::class.simpleName.orEmpty()
}
