package io.github.anmirror.phone.service

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.github.anmirror.feature.notify.AndroidActionInvoker
import io.github.anmirror.feature.notify.AndroidNotificationReader
import io.github.anmirror.phone.AppGraph

/**
 * Hands the phone's notifications to the [io.github.anmirror.feature.notify.NotifyBridge] held by
 * [AppGraph]. The system binds this service only while the user has granted notification access.
 */
class PhoneNotificationListener : NotificationListenerService() {
    private val graph get() = AppGraph.get(this)
    private val reader by lazy { AndroidNotificationReader(this) }

    override fun onListenerConnected() {
        graph.notifyInvoker.target = AndroidActionInvoker(
            context = this,
            reader = reader,
            activeNotifications = { runCatching { activeNotifications }.getOrNull() },
            cancel = { key -> cancelNotification(key) },
        )
        // After the invoker is in place: a resync triggered by the access change reads from it.
        graph.setNotifyAccess(true)
    }

    override fun onListenerDisconnected() {
        graph.notifyInvoker.target = null
        graph.refreshNotifyAccess()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        // Nothing is read while the feature is off or no Mac listens.
        if (!graph.notifyOpen()) return
        val snapshot = reader.snapshot(sbn)
        graph.postNotifyEvent { graph.notifyBridge.onPosted(snapshot) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val key = sbn.key
        graph.postNotifyEvent { graph.notifyBridge.onRemoved(key) }
    }
}
