package io.github.anmirror.phone

import io.github.anmirror.phone.platform.leftoverSelection
import kotlin.test.Test
import kotlin.test.assertEquals

class DownloadsSweepTest {
    @Test fun sweepSelectsOnlyOurPendingRowsInOurFolder() {
        val (selection, args) = leftoverSelection("io.github.anmirror.phone", liveIds = emptyList())
        assertEquals("relative_path=? AND is_pending=1 AND owner_package_name=?", selection)
        assertEquals(listOf("Download/Android Mirroring/", "io.github.anmirror.phone"), args.toList())
    }

    @Test fun sweepSkipsRowsBeingWritten() {
        val (selection, args) = leftoverSelection("pkg", liveIds = listOf(7L, 9L))
        assertEquals("relative_path=? AND is_pending=1 AND owner_package_name=? AND _id NOT IN (?,?)", selection)
        assertEquals(listOf("Download/Android Mirroring/", "pkg", "7", "9"), args.toList())
    }
}
