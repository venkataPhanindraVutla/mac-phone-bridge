package io.github.anmirror.phone

import io.github.anmirror.phone.platform.BackupRotation
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class BackupRotationTest {
    @Test
    fun keepsTheLastThreeNewestFirst() {
        val dir = Files.createTempDirectory("bak").toFile()
        val f = File(dir, "paired-macs.bin")
        for (i in 1..5) {
            f.writeText("v$i")
            BackupRotation.keep(f, 3)
        }
        assertEquals("v5", File(dir, "paired-macs.bin.bak1").readText())
        assertEquals("v4", File(dir, "paired-macs.bin.bak2").readText())
        assertEquals("v3", File(dir, "paired-macs.bin.bak3").readText())
        assertFalse(File(dir, "paired-macs.bin.bak4").exists())
    }

    @Test
    fun missingSourceDoesNothing() {
        val dir = Files.createTempDirectory("bak").toFile()
        BackupRotation.keep(File(dir, "none"), 3)
        assertEquals(0, dir.list()!!.size)
    }
}
