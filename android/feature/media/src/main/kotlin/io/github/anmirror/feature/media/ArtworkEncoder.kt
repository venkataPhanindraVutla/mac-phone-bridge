package io.github.anmirror.feature.media

import android.graphics.Bitmap
import androidx.core.graphics.scale
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.roundToInt

/** Media artwork as a JPEG within the wire limits (SPEC 20): long edge 300 px, at most 96 KB. */
object ArtworkEncoder {
    const val LONG_EDGE = 300
    const val MAX_BYTES = 98_304
    val QUALITIES = listOf(85, 70, 55, 40)

    /** Scaled down to [LONG_EDGE] (never up), then [fit]; null when it does not fit and is dropped. */
    fun encode(source: Bitmap): ByteArray? {
        if (source.width <= 0 || source.height <= 0) return null
        var bitmap = source
        if (bitmap.config == Bitmap.Config.HARDWARE) {
            bitmap = bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return null
        }
        val longEdge = max(bitmap.width, bitmap.height)
        if (longEdge > LONG_EDGE) {
            val scale = LONG_EDGE.toFloat() / longEdge
            val scaled = bitmap.scale(
                max(1, (bitmap.width * scale).roundToInt()),
                max(1, (bitmap.height * scale).roundToInt()),
            )
            if (bitmap !== source) bitmap.recycle()
            bitmap = scaled
        }
        val frame = bitmap
        return try {
            fit { quality ->
                val out = ByteArrayOutputStream()
                frame.compress(Bitmap.CompressFormat.JPEG, quality, out)
                out.toByteArray()
            }
        } finally {
            if (frame !== source) frame.recycle()
        }
    }

    /** The first of [QUALITIES] whose encoding fits in [MAX_BYTES]; null when none does. */
    fun fit(encodeAt: (Int) -> ByteArray): ByteArray? {
        for (quality in QUALITIES) {
            val bytes = encodeAt(quality)
            if (bytes.isNotEmpty() && bytes.size <= MAX_BYTES) return bytes
        }
        return null
    }
}
