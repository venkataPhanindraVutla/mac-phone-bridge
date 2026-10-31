package io.github.anmirror.feature.mirror

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

@OptIn(ExperimentalCoroutinesApi::class)
class HelperInstallerTest {
    private val jar = ByteArray(300_000) { (it * 7).toByte() }

    @Test
    fun pushesThenVerifies() = runTest {
        val adb = MirrorAdb()
        // The first two checks see a jar still being written.
        adb.shaLine = { n -> if (n < 3) "0000  x\n" else "${MirrorAdb.SHA}  ${ServerCommand.JAR_PATH}\n" }
        HelperInstaller(adb, { jar.inputStream() }, MirrorAdb.SHA).install()
        assertEquals(listOf("exec:cat > /data/local/tmp/anmirror-helper.jar"), adb.opens)
        assertContentEquals(jar, adb.pushed.toByteArray())
        assertEquals(List(3) { "sha256sum /data/local/tmp/anmirror-helper.jar" }, adb.shells)
        assertEquals(400, currentTime)
    }

    @Test
    fun shaMismatchFails() = runTest {
        val adb = MirrorAdb()
        adb.shaLine = { "deadbeef  ${ServerCommand.JAR_PATH}\n" }
        assertFailsWith<IOException> { HelperInstaller(adb, { jar.inputStream() }, MirrorAdb.SHA).install() }
        assertEquals(20, adb.shells.size)
        assertEquals(19 * 200L, currentTime)
    }
}
