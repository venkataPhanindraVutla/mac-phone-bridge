package io.github.anmirror.feature.notify

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import kotlin.math.max

/** Notification picture to JPEG within the wire limits: long edge at most 720 px, at most 300 KB. */
object ImageScaler {
    const val MAX_EDGE = 720
    const val MAX_BYTES = 300 * 1024
    private const val FIRST_QUALITY = 80
    private const val SECOND_QUALITY = 60

    /** Null when it does not fit after one re-encode at quality 60. */
    fun toJpeg(source: Bitmap): ByteArray? {
        var bitmap = source
        if (bitmap.config == Bitmap.Config.HARDWARE) {
            bitmap = bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return null
        }
        val longEdge = max(bitmap.width, bitmap.height)
        if (longEdge > MAX_EDGE) {
            val scale = MAX_EDGE.toFloat() / longEdge
            bitmap = Bitmap.createScaledBitmap(
                bitmap,
                max(1, (bitmap.width * scale).toInt()),
                max(1, (bitmap.height * scale).toInt()),
                true,
            )
        }
        for (quality in intArrayOf(FIRST_QUALITY, SECOND_QUALITY)) {
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            if (out.size() <= MAX_BYTES) return out.toByteArray()
        }
        return null
    }
}
