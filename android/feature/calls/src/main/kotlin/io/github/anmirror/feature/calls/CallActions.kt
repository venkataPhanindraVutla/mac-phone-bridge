package io.github.anmirror.feature.calls

import android.Manifest
import android.app.Notification
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.telecom.TelecomManager
import androidx.core.os.BundleCompat

/** Things the phone can do to a call. Every method reports whether it was carried out; none throws. */
interface CallActions {
    /** False when this way of acting has nothing to act with right now (no permission, no notification). */
    fun isAvailable(): Boolean = true
    fun answer(): Boolean
    /** Declines a ringing call or hangs up an active one. */
    fun end(): Boolean
    fun setMuted(muted: Boolean): Boolean
    /** The microphone's mute state; null = unknown. */
    fun isMuted(): Boolean?
}

/**
 * [TelecomManager.acceptRingingCall] / [TelecomManager.endCall] (ANSWER_PHONE_CALLS) and the
 * microphone mute of [AudioManager]. Call audio itself stays on the phone.
 */
class TelecomCallActions(context: Context) : CallActions {
    private val app = context.applicationContext
    private val telecom = app.getSystemService(TelecomManager::class.java)
    private val audio = app.getSystemService(AudioManager::class.java)

    override fun isAvailable(): Boolean =
        app.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    override fun answer(): Boolean = guarded {
        telecom.acceptRingingCall()
        true
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    override fun end(): Boolean = guarded { telecom.endCall() }

    override fun setMuted(muted: Boolean): Boolean = guarded {
        audio.isMicrophoneMute = muted
        true
    }

    override fun isMuted(): Boolean? = try {
        audio.isMicrophoneMute
    } catch (e: RuntimeException) {
        null
    }

    private fun guarded(block: () -> Boolean): Boolean = try {
        isAvailable() && block()
    } catch (e: SecurityException) {
        false
    } catch (e: RuntimeException) {
        false
    }
}

/**
 * Fires the answer / decline / hang-up intents of the dialer's own call notification
 * (`Notification.CallStyle`, API 31+). [activeCallNotification] is the active `category == call`
 * notification, or null (also when the notification listener is not bound). Cannot mute.
 */
class CallStyleCallActions(private val activeCallNotification: () -> Notification?) : CallActions {
    override fun isAvailable(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && activeCallNotification() != null

    override fun answer(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && fire(Notification.EXTRA_ANSWER_INTENT)

    /** A ringing call's notification carries Decline, an ongoing one's Hang up. */
    override fun end(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
        (fire(Notification.EXTRA_DECLINE_INTENT) || fire(Notification.EXTRA_HANG_UP_INTENT))

    override fun setMuted(muted: Boolean): Boolean = false

    override fun isMuted(): Boolean? = null

    private fun fire(extra: String): Boolean {
        val extras = activeCallNotification()?.extras ?: return false
        val intent = BundleCompat.getParcelable(extras, extra, PendingIntent::class.java) ?: return false
        return try {
            intent.send()
            true
        } catch (e: PendingIntent.CanceledException) {
            false
        }
    }
}
