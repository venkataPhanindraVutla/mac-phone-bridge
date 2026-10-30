package io.github.anmirror.phone.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat

/**
 * Calls [onScreenOn] when the screen turns on: the user is about to use the phone, so a dead
 * connection should be found now, not at the next timer. `ACTION_SCREEN_ON` reaches only
 * receivers registered at run time, so the service owns this one.
 */
class ScreenOnKicker(private val context: Context, private val onScreenOn: () -> Unit) {
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_ON) onScreenOn()
        }
    }
    private var registered = false

    fun start() {
        if (registered) return
        ContextCompat.registerReceiver(context, receiver, IntentFilter(Intent.ACTION_SCREEN_ON), ContextCompat.RECEIVER_NOT_EXPORTED)
        registered = true
    }

    fun stop() {
        if (!registered) return
        registered = false
        runCatching { context.unregisterReceiver(receiver) }
    }
}
