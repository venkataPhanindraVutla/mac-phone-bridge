package io.github.anmirror.feature.media

import android.graphics.Bitmap
import android.graphics.Color
import androidx.core.graphics.applyCanvas
import androidx.core.graphics.createBitmap
import androidx.core.graphics.scale
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.roundToInt

/** Media artwork as a JPEG within the wire limits (SPEC 20): long edge 300 px, at most 96 KB. */
object ArtworkEncoder {
    const val LONG_EDGE = 300
    const val MAX_BYTES = 98_304
    val QUALITIES = listOf(85, 70, 55, 40)

    /**
     * Scaled down to [LONG_EDGE] (never up), drawn on white when it has transparency (JPEG has
     * none; an app icon would otherwise come out on black), then [fit]. Null when it does not fit
     * and is dropped. [source] is never recycled.
     */
    fun encode(source: Bitmap): ByteArray? {
        if (source.width <= 0 || source.height <= 0) return null
        var bitmap = source
        fun replace(next: Bitmap) {
            if (bitmap !== source && bitmap !== next) bitmap.recycle()
            bitmap = next
        }
        if (bitmap.config == Bitmap.Config.HARDWARE) {
            replace(bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return null)
        }
        val longEdge = max(bitmap.width, bitmap.height)
        if (longEdge > LONG_EDGE) {
            val scale = LONG_EDGE.toFloat() / longEdge
            replace(
                bitmap.scale(
                    max(1, (bitmap.width * scale).roundToInt()),
                    max(1, (bitmap.height * scale).roundToInt()),
                ),
            )
        }
        if (bitmap.hasAlpha()) {
            val transparent = bitmap
            replace(
                createBitmap(transparent.width, transparent.height).applyCanvas {
                    drawColor(Color.WHITE)
                    drawBitmap(transparent, 0f, 0f, null)
                },
            )
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
