package io.github.anmirror.transfer

import java.io.ByteArrayOutputStream
import kotlin.test.Test
import kotlin.test.assertContentEquals

class ThumbRecordsTest {
    @Test
    fun writesIdLengthJpegAndTerminator() {
        val out = ByteArrayOutputStream()
        ThumbRecords.write(out, 0x0102030405060708L, byteArrayOf(9, 8, 7))
        ThumbRecords.write(out, 5, null)
        ThumbRecords.end(out)
        val expected = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 3, 9, 8, 7) +
            byteArrayOf(0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0) +
            ByteArray(12)
        assertContentEquals(expected, out.toByteArray())
    }
}
