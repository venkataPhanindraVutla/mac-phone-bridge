package io.github.anmirror.feature.notify

import io.github.anmirror.protocol.v1.NotificationFilter

fun snap(
    key: String = "k1",
    pkg: String = "com.chat",
    title: String = "Alice",
    text: String = "hi",
    actions: List<ActionSnapshot> = emptyList(),
    ongoing: Boolean = false,
    groupSummary: Boolean = false,
    foregroundService: Boolean = false,
    mediaStyle: Boolean = false,
    category: String? = null,
    onlyAlertOnce: Boolean = false,
    clearable: Boolean = true,
) = NotificationSnapshot(
    key, pkg, "Chat", title, text, "", 1000L, actions, ongoing, groupSummary, foregroundService,
    mediaStyle, category, onlyAlertOnce, clearable,
)

fun filter(enabled: Boolean = true, vararg muted: String): NotificationFilter =
    NotificationFilter.newBuilder().setEnabled(enabled).addAllMutedPackages(muted.toList()).build()
