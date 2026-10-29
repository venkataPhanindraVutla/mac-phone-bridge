package io.github.anmirror.feature.photos

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import kotlin.math.max

/**
 * A thumbnail to JPEG within the wire limits (Global Constraints): long edge at most 256 px,
 * quality 80, re-encoded once at 60 if over 64 KB; null (sent empty) if it still does not fit.
 */
object ThumbnailEncoder {
    const val EDGE = 256
    const val MAX_BYTES = 64 * 1024
    private const val FIRST_QUALITY = 80
    private const val SECOND_QUALITY = 60

    fun toJpeg(source: Bitmap): ByteArray? {
        var bitmap = source
        if (bitmap.config == Bitmap.Config.HARDWARE) {
            bitmap = bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return null
        }
        val longEdge = max(bitmap.width, bitmap.height)
        if (longEdge > EDGE) {
            val scale = EDGE.toFloat() / longEdge
            bitmap = Bitmap.createScaledBitmap(
                bitmap,
                max(1, (bitmap.width * scale).toInt()),
                max(1, (bitmap.height * scale).toInt()),
                true,
            )
        }
        try {
            for (quality in intArrayOf(FIRST_QUALITY, SECOND_QUALITY)) {
                val out = ByteArrayOutputStream()
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) return null
                if (out.size() <= MAX_BYTES) return out.toByteArray()
            }
            return null
        } finally {
            if (bitmap !== source) bitmap.recycle()
        }
    }
}
