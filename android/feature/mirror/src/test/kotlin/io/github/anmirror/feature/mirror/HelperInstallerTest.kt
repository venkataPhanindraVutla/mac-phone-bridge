package io.github.anmirror.feature.mirror

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.Closeable
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class HelperInstallerTest {
    private val jar = ByteArray(300_000) { (it * 7).toByte() }

    private val path = ServerCommand.jarPath(0x0a1b2c3d)
    private val registered = mutableListOf<Closeable>()
    private val register: (Closeable) -> Boolean = { registered += it; true }

    @Test
    fun pushesThenVerifies() = runTest {
        val adb = MirrorAdb()
        // The first two checks see a jar still being written.
        adb.shaLine = { n -> if (n < 3) "0000  x\n" else "${MirrorAdb.SHA}  $path\n" }
        HelperInstaller(adb, { jar.inputStream() }, MirrorAdb.SHA).install(path, register)
        assertEquals(listOf("exec:cat > /data/local/tmp/anmirror-helper-0a1b2c3d.jar"), adb.opens)
        assertContentEquals(jar, adb.pushed.toByteArray())
        // Old leftovers swept first, then the checks of this session's own jar.
        assertEquals(listOf(ServerCommand.sweepStaleJars()) + List(3) { "sha256sum /data/local/tmp/anmirror-helper-0a1b2c3d.jar" }, adb.shells)
        assertEquals(400, currentTime)
        // M4: the push pipe joined the session's close group.
        assertEquals(1, registered.size)
    }

    /** M4: a session that already ended refuses the push pipe; nothing is pushed. */
    @Test
    fun pushAfterTheSessionClosedFails() = runTest {
        val adb = MirrorAdb()
        assertFailsWith<IOException> { HelperInstaller(adb, { jar.inputStream() }, MirrorAdb.SHA).install(path) { false } }
        assertEquals(0, adb.pushed.size())
        assertTrue(adb.shells.none { it.startsWith("sha256sum") })
    }

    /** M4: adbd going silent mid-push can't wedge the session: closing its group ends the push. */
    @Test
    fun stalledPushEndsWhenTheGroupCloses() = runBlocking {
        val adb = MirrorAdb()
        adb.pushStalls = true
        val pipes = mutableListOf<Closeable>()
        val install = async(Dispatchers.Default) {
            runCatching { HelperInstaller(adb, { jar.inputStream() }, MirrorAdb.SHA).install(path) { synchronized(pipes) { pipes += it }; true } }
        }
        assertTrue(adb.pushEntered.await(5, TimeUnit.SECONDS))
        synchronized(pipes) { pipes.forEach { it.close() } }
        val result = withTimeout(5_000) { install.await() }
        assertTrue(result.exceptionOrNull() is IOException, result.toString())
    }

    @Test
    fun malformedExpectedHashFailsClosed() = runTest {
        val adb = MirrorAdb()
        adb.shaLine = { "\n" } // sha256sum printed nothing
        for (bad in listOf("", "abc", "z".repeat(64))) {
            assertFailsWith<IOException> { HelperInstaller(adb, { jar.inputStream() }, bad).install(path, register) }
        }
        assertTrue(adb.opens.isEmpty(), "nothing pushed")
        assertTrue(adb.shells.isEmpty(), "nothing run")
    }

    @Test
    fun shaMismatchFails() = runTest {
        val adb = MirrorAdb()
        adb.shaLine = { "deadbeef  $path\n" }
        assertFailsWith<IOException> { HelperInstaller(adb, { jar.inputStream() }, MirrorAdb.SHA).install(path, register) }
        assertEquals(20, adb.shells.count { it.startsWith("sha256sum ") })
        assertEquals(19 * 200L, currentTime)
    }
}
