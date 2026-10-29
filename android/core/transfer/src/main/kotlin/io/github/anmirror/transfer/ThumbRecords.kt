package io.github.anmirror.transfer

import java.io.OutputStream

/** `photos.thumbs` bulk records (SPEC 18): `uint64_be id | uint32_be length | JPEG`, ended by id 0. */
object ThumbRecords {
    /** Writes one record; a null or empty [jpeg] means "no thumbnail" (length 0). Does not flush. */
    fun write(out: OutputStream, id: Long, jpeg: ByteArray?) {
        val len = jpeg?.size ?: 0
        val head = ByteArray(12)
        for (i in 0 until 8) head[i] = (id ushr (56 - 8 * i)).toByte()
        for (i in 0 until 4) head[8 + i] = (len ushr (24 - 8 * i)).toByte()
        out.write(head)
        if (jpeg != null && len > 0) out.write(jpeg)
    }

    /** Writes the terminating record (`id = 0, length = 0`). Does not flush. */
    fun end(out: OutputStream) = write(out, 0, null)
}
