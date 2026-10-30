package io.github.anmirror.phone

import io.github.anmirror.phone.diag.KeepAliveEvent
import io.github.anmirror.phone.diag.KeepAliveLog
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class KeepAliveLogTest {
    private fun tmp(): File = Files.createTempDirectory("kalog").toFile()

    @Test
    fun lineIsUtcTimeCodeAndDetail() {
        val f = File(tmp(), "k.log")
        KeepAliveLog(f, clock = { 1_700_000_000_000 }).record(KeepAliveEvent.SERVICE_START, "restart=true")
        assertEquals(listOf("2023-11-14T22:13:20Z service-start restart=true"), f.readLines())
    }

    @Test
    fun detailIsSanitised() {
        val f = File(tmp(), "k.log")
        KeepAliveLog(f).record(KeepAliveEvent.STATE, "Ada's Mac 10.0.0.5")
        assertTrue(f.readLines().single().endsWith(" state Ada_s_Mac_10.0.0.5"))
    }

    @Test
    fun keepsNewest500Lines() {
        val f = File(tmp(), "k.log")
        val log = KeepAliveLog(f)
        for (i in 0 until 1234) log.record(KeepAliveEvent.STATE, "n=$i")
        val lines = f.readLines()
        assertTrue(lines.size in 500..600, "size ${lines.size}")
        assertTrue(lines.last().endsWith("n=1233"))
    }

    @Test
    fun recordNeverThrows() {
        val dir = tmp()
        val f = File(File(dir, "gone"), "k.log")
        KeepAliveLog(f).record(KeepAliveEvent.APP_OPEN, "x")
    }
}
