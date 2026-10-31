package io.github.anmirror.phonesim

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class SimMirrorTest {
    private val sample = File("../../../protocol/testdata/mirror/sample-h264-320x640.scrcpy").readBytes()

    @Test
    fun sampleSplitsIntoHeaderSessionConfigAndSixtyFrames() {
        val chunks = MirrorSample.chunks(sample)
        assertEquals(68, chunks[0].bytes.size)
        assertEquals(1 + 1 + 1 + 60, chunks.size)
        val media = chunks.mapNotNull { it.ptsUs }
        assertEquals(60, media.size)
        assertEquals(media.sorted(), media)
        assertContentEquals(sample, chunks.fold(ByteArray(0)) { acc, c -> acc + c.bytes })
    }

    @Test
    fun playPacesFramesByTheirPts() {
        val chunks = MirrorSample.chunks(sample)
        var now = 0L
        val sleeps = mutableListOf<Long>()
        val out = ByteArrayOutputStream()
        MirrorSample.play(chunks, out, nanoTime = { now }, sleep = { sleeps += it; now += it })
        assertContentEquals(sample, out.toByteArray())
        val pts = chunks.mapNotNull { it.ptsUs }
        // One wait per frame after the first; the whole sample spans its PTS range (about a second at 60 fps).
        assertEquals(59, sleeps.size)
        assertEquals((pts.last() - pts.first()) * 1_000, now)
        assertEquals(true, now in 900_000_000L..1_100_000_000L)
    }

    @Test
    fun controlReaderReportsTouchActionsAndSkipsTheRest() {
        val touch = { action: Int -> byteArrayOf(2, action.toByte()) + ByteArray(30) }
        val stream = byteArrayOf(10, 0) + // SET_DISPLAY_POWER off
            touch(0) +
            byteArrayOf(1, 0, 0, 0, 2, 'h'.code.toByte(), 'i'.code.toByte()) + // INJECT_TEXT "hi"
            byteArrayOf(3) + ByteArray(20) + // scroll
            touch(1) +
            byteArrayOf(17) + // RESET_VIDEO
            byteArrayOf(9) + ByteArray(9) + byteArrayOf(0, 0, 0, 1, 'x'.code.toByte()) + // SET_CLIPBOARD
            byteArrayOf(0) + ByteArray(13) // keycode
        val touches = mutableListOf<Int>()
        val unknown = mutableListOf<Int>()
        readControl(ByteArrayInputStream(stream), touches::add, unknown::add)
        assertEquals(listOf(0, 1), touches)
        assertEquals(emptyList(), unknown)

        readControl(ByteArrayInputStream(byteArrayOf(99, 1, 2)), touches::add, unknown::add)
        assertEquals(listOf(99), unknown)
    }
}
