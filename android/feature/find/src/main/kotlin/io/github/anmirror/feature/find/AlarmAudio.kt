package io.github.anmirror.feature.find

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import kotlin.math.PI
import kotlin.math.sin

/** The alarm stream: its volume and a looping sound (plus vibration). */
interface AlarmAudio {
    fun volume(): Int
    fun maxVolume(): Int
    fun setVolume(v: Int)
    fun startLoop()
    fun stopLoop()
}

/**
 * Plays the default alarm sound on the alarm stream (USAGE_ALARM), looping; with no default alarm
 * it plays a tone generated in code. Vibrates with alarm usage, which also passes Do Not Disturb.
 */
class AndroidAlarmAudio(context: Context) : AlarmAudio {
    private val app = context.applicationContext
    private val am = app.getSystemService(AudioManager::class.java)
    private var player: MediaPlayer? = null
    private var tone: AudioTrack? = null

    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    override fun volume() = am.getStreamVolume(AudioManager.STREAM_ALARM)
    override fun maxVolume() = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)

    override fun setVolume(v: Int) {
        try {
            am.setStreamVolume(AudioManager.STREAM_ALARM, v, 0)
        } catch (e: SecurityException) {
            Log.w(TAG, "alarm volume not changed (${e.javaClass.simpleName})")
        }
    }

    @Synchronized
    override fun startLoop() {
        if (player != null || tone != null) return
        if (!startDefaultAlarm()) startTone()
        vibrate(true)
    }

    @Synchronized
    override fun stopLoop() {
        player?.let { runCatching { it.stop() }; it.release() }
        player = null
        tone?.let { runCatching { it.stop() }; it.release() }
        tone = null
        vibrate(false)
    }

    private fun startDefaultAlarm(): Boolean {
        val uri = RingtoneManager.getActualDefaultRingtoneUri(app, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: return false
        val p = MediaPlayer()
        return try {
            p.setAudioAttributes(attributes)
            p.setDataSource(app, uri)
            p.isLooping = true
            p.setOnPreparedListener { it.start() }
            p.setOnErrorListener { mp, _, _ ->
                // The sound is unplayable: fall back to the generated tone.
                synchronized(this) {
                    if (player === mp) {
                        mp.release()
                        player = null
                        // Runs on the main thread: a failing tone must not crash the app.
                        try {
                            startTone()
                        } catch (e: Exception) {
                            Log.w(TAG, "fallback tone failed (${e.javaClass.simpleName})")
                        }
                    }
                }
                true
            }
            p.prepareAsync() // not blocking the connection's read loop
            player = p
            true
        } catch (e: Exception) {
            p.release()
            Log.w(TAG, "default alarm unavailable (${e.javaClass.simpleName})")
            false
        }
    }

    /** A 1 s two-pitch beep loop, generated in code. */
    private fun startTone() {
        val rate = 22_050
        val samples = ShortArray(rate)
        for (i in samples.indices) {
            val freq = if (i < rate / 2) 880.0 else 1_175.0
            val envelope = if (i % (rate / 2) < rate / 20) 1.0 else 0.9
            samples[i] = (sin(2 * PI * freq * i / rate) * envelope * Short.MAX_VALUE * 0.9).toInt().toShort()
        }
        val track = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(samples.size * 2)
            .build()
        track.write(samples, 0, samples.size)
        track.setLoopPoints(0, samples.size, -1)
        track.play()
        tone = track
    }

    @Suppress("DEPRECATION")
    private fun vibrate(on: Boolean) {
        val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            app.getSystemService(VibratorManager::class.java).defaultVibrator
        } else {
            app.getSystemService(Vibrator::class.java)
        }
        if (!on) {
            vibrator.cancel()
            return
        }
        vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 800, 600), 0), attributes)
    }

    private companion object {
        const val TAG = "AnMirror"
    }
}
