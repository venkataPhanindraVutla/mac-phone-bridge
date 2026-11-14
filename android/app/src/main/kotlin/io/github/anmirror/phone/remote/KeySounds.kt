package io.github.anmirror.phone.remote

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin
import kotlin.random.Random

/**
 * The Mac keyboard's key sounds: a short click with a low thock on press and a lighter tick on
 * release. Both are made here at start (no sound files), into static tracks that replay at once.
 */
class KeySounds {
    private val press = track(click(seconds = 0.07, noiseMs = 30.0, centerHz = 2_400.0, noiseGain = 0.42, thock = true))
    private val release = track(click(seconds = 0.025, noiseMs = 18.0, centerHz = 3_800.0, noiseGain = 0.18, thock = false))

    fun play(down: Boolean) {
        val t = if (down) press else release
        runCatching {
            t.pause()
            t.playbackHeadPosition = 0
            t.play()
        }
    }

    fun release() {
        press.release()
        release.release()
    }

    private fun track(pcm: ShortArray): AudioTrack = AudioTrack.Builder()
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
        )
        .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
        .setTransferMode(AudioTrack.MODE_STATIC)
        .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        .setBufferSizeInBytes(pcm.size * 2)
        .build()
        .also { it.write(pcm, 0, pcm.size) }

    private companion object {
        const val RATE = 44_100

        /** Decaying noise through a band-pass (the click), plus a falling sine (the thock). */
        fun click(seconds: Double, noiseMs: Double, centerHz: Double, noiseGain: Double, thock: Boolean): ShortArray {
            val n = (RATE * seconds).toInt()
            val noiseN = (RATE * noiseMs / 1000).toInt()
            val random = Random(7) // the same sound every run
            // RBJ band-pass biquad, Q 1.2.
            val w = 2 * PI * centerHz / RATE
            val alpha = sin(w) / (2 * 1.2)
            val a0 = 1 + alpha
            val b0 = alpha / a0
            val b2 = -alpha / a0
            val a1 = -2 * kotlin.math.cos(w) / a0
            val a2 = (1 - alpha) / a0
            var x1 = 0.0; var x2 = 0.0; var y1 = 0.0; var y2 = 0.0
            var phase = 0.0
            return ShortArray(n) { i ->
                val x = if (i < noiseN) (random.nextDouble() * 2 - 1) * (1 - i.toDouble() / noiseN).pow(3) else 0.0
                val y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                var s = y * noiseGain * 3
                if (thock) {
                    val t = i.toDouble() / RATE
                    phase += 2 * PI * (70 + 110 * exp(-t / 0.02)) / RATE
                    s += sin(phase) * 0.28 * exp(-t / 0.012)
                }
                (s.coerceIn(-1.0, 1.0) * Short.MAX_VALUE).toInt().toShort()
            }
        }
    }
}
