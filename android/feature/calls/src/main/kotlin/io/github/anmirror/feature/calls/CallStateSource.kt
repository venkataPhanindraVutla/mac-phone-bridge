package io.github.anmirror.feature.calls

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager

enum class TelephonyPhase { IDLE, RINGING, OFFHOOK }

/** The phone's call state, as the telephony stack reports it (one state for the whole phone). */
interface CallStateSource {
    /** Starts reporting; the current state is reported straight away. [onChange] may run on any thread. */
    fun start(onChange: (TelephonyPhase, number: String?) -> Unit)
    fun stop()
}

internal fun phaseOf(callState: Int): TelephonyPhase = when (callState) {
    TelephonyManager.CALL_STATE_RINGING -> TelephonyPhase.RINGING
    TelephonyManager.CALL_STATE_OFFHOOK -> TelephonyPhase.OFFHOOK
    else -> TelephonyPhase.IDLE
}

/**
 * [TelephonyCallback.CallStateListener] on API 31+ (no number is delivered there), the deprecated
 * [PhoneStateListener] on 29-30 (the number only shows with READ_CALL_LOG). Needs READ_PHONE_STATE.
 */
class AndroidCallStateSource(context: Context) : CallStateSource {
    private val telephony = context.applicationContext.getSystemService(TelephonyManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var callback: TelephonyCallback? = null
    private var legacy: PhoneStateListener? = null

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    override fun start(onChange: (TelephonyPhase, String?) -> Unit) {
        stop()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) = onChange(phaseOf(state), null)
            }
            callback = cb
            telephony.registerTelephonyCallback(Runnable::run, cb)
        } else {
            // A PhoneStateListener binds to the looper of the thread that makes it: the main one.
            main.post {
                val l = object : PhoneStateListener() {
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) = onChange(phaseOf(state), phoneNumber)
                }
                legacy = l
                telephony.listen(l, PhoneStateListener.LISTEN_CALL_STATE)
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            callback?.let { telephony.unregisterTelephonyCallback(it) }
            callback = null
        } else {
            main.post {
                legacy?.let { telephony.listen(it, PhoneStateListener.LISTEN_NONE) }
                legacy = null
            }
        }
    }
}
