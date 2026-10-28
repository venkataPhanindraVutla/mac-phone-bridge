package io.github.anmirror.feature.notify

/** One action button of a notification, in the notification's own order. */
data class ActionSnapshot(val title: String, val isReply: Boolean, val replyHint: String?)

/** Everything the bridge needs to know about a notification; keeps `StatusBarNotification` out of the pure logic. */
data class NotificationSnapshot(
    val key: String,
    val packageName: String,
    val appName: String,
    val title: String,
    val text: String,
    val subText: String,
    val postedAtMs: Long,
    val actions: List<ActionSnapshot>,
    val ongoing: Boolean,
    val groupSummary: Boolean,
    val foregroundService: Boolean,
    val mediaStyle: Boolean,
    val category: String?,
    val onlyAlertOnce: Boolean,
    val clearable: Boolean,
)
