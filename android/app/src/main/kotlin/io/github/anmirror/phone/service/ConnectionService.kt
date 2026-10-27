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
import io.github.anmirror.phone.R
import io.github.anmirror.phone.TAG
import io.github.anmirror.phone.copyNamesMac
import io.github.anmirror.phone.macOrNull
import io.github.anmirror.phone.messageRes
import io.github.anmirror.phone.platform.NetworkWatcher
import kotlinx.coroutines.flow.combine
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

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph.get(this)
        createChannel()
        goForeground(getString(R.string.state_looking_unnamed))
        network = NetworkWatcher(this) { graph.manager.kick() }
        network.start()
        graph.manager.start()
        lifecycleScope.launch {
            combine(graph.manager.state, graph.store.macs) { state, macs -> state to macs }
                .distinctUntilChanged()
                .collect { (state, macs) -> onState(state, macs) }
        }
        Log.i(TAG, "service: created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        // Every start must be followed by startForeground, also a sticky restart.
        goForeground(lastText ?: getString(R.string.state_looking_unnamed))
        Log.i(TAG, "service: start (restart=${intent == null})")
        return START_STICKY
    }

    override fun onDestroy() {
        network.stop()
        graph.manager.stop()
        Log.i(TAG, "service: destroyed")
        super.onDestroy()
    }

    private fun onState(state: PhoneConnectionState, macs: List<PairedMac>?) {
        Log.i(TAG, "state: ${state.describe()}")
        if (state == PhoneConnectionState.NotPaired) {
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
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, ConnectionService::class.java))
        }
    }
}

/** For logs: no discovery key, no addresses. */
private fun PhoneConnectionState.describe(): String = when (this) {
    is PhoneConnectionState.Connected -> "Connected(shared=${shared.sorted().joinToString(",")})"
    else -> this::class.simpleName.orEmpty()
}
