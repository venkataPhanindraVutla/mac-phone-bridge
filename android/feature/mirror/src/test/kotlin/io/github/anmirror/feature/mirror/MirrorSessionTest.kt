package io.github.anmirror.feature.mirror

import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.MirrorPhase
import io.github.anmirror.protocol.v1.MirrorReason
import io.github.anmirror.protocol.v1.MirrorStart
import io.github.anmirror.protocol.v1.MirrorState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class MirrorSessionTest {
    /** Pinned (R53): the helper's own command line, never the jar path or its clean-up process. */
    private val KILL = "pkill -f 'com.genymobile.scrcpy.[S]erver 5.0.1-am1'"

    private val video = FakeSocket(dummy = 0)
    private val audio = FakeSocket()
    private val control = FakeSocket()
    private val adb = MirrorAdb()
    private val dialer = FakeDialer()
    private val states = Channel<MirrorState>(Channel.UNLIMITED)
    private var adbLost = 0

    private fun TestScope.session(
        start: MirrorStart = mirrorStart(),
        dialer: LinkDialer = this@MirrorSessionTest.dialer,
        connect: suspend () -> MirrorReason? = { null },
    ) = MirrorSession(
        start = start,
        adb = adb,
        installer = HelperInstaller(adb, { ByteArray(64).inputStream() }, MirrorAdb.SHA, io = EmptyCoroutineContext),
        dialer = dialer,
        clipboardAutosync = true,
        version = "5.0.1-am1",
        report = { states.send(it) },
        scope = backgroundScope,
        clock = { currentTime },
        connect = connect,
        onAdbLost = { adbLost++ },
        io = EmptyCoroutineContext,
        newScid = { 0x0a1b2c3d },
    )

    private fun planAll(audioOn: Boolean = true) {
        adb.plan += SocketPlan.Open(video)
        if (audioOn) adb.plan += SocketPlan.Open(audio)
        adb.plan += SocketPlan.Open(control)
    }

    private suspend fun next(): Pair<MirrorPhase, MirrorReason> = states.receive().let { it.phase to it.reason }

    private val starting = MirrorPhase.MIRROR_PHASE_STARTING to MirrorReason.MIRROR_REASON_UNSPECIFIED
    private val running = MirrorPhase.MIRROR_PHASE_RUNNING to MirrorReason.MIRROR_REASON_UNSPECIFIED
    private fun failed(r: MirrorReason) = MirrorPhase.MIRROR_PHASE_FAILED to r
    private fun stopped(r: MirrorReason) = MirrorPhase.MIRROR_PHASE_STOPPED to r

    @Test
    fun startReportsStartingThenRunning() = runTest {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        assertEquals(starting, next())
        assertEquals(running, next())
        // Links in order, each with the big send buffer.
        assertEquals(listOf(BulkRole.BULK_ROLE_MIRROR_VIDEO, BulkRole.BULK_ROLE_MIRROR_AUDIO, BulkRole.BULK_ROLE_MIRROR_CONTROL), dialer.links.map { it.role })
        assertTrue(dialer.links.all { it.sendBuffer == 262_144 })
        assertEquals(mirrorStart().tokens.video, dialer.link(BulkRole.BULK_ROLE_MIRROR_VIDEO).token)
        // Kill, push, verify, launch, then the sockets.
        assertEquals(KILL, adb.shells.first())
        val launch = adb.opens.single { it.startsWith("shell:") }
        assertEquals("shell:" + ServerCommand.build(HelperOptions.from(mirrorStart(), 0x0a1b2c3d, true), "5.0.1-am1"), launch)
        assertEquals(3, adb.opens.count { it == "localabstract:scrcpy_0a1b2c3d" })
        s.stop(MirrorReason.MIRROR_REASON_USER)
        assertEquals(stopped(MirrorReason.MIRROR_REASON_USER), next())
        job.join()
    }

    @Test
    fun videoOpenRetriesUntilDummyByte() = runTest {
        adb.plan += listOf(SocketPlan.Refuse, SocketPlan.Refuse, SocketPlan.Eof)
        planAll()
        val s = session()
        val job = launch { s.run {} }
        assertEquals(starting, next())
        assertEquals(running, next())
        assertEquals(6, adb.opens.count { it.startsWith("localabstract:") })
        assertTrue(currentTime >= 300, "retried every 100 ms, at $currentTime")
        s.stop(null)
        job.join()
    }

    @Test
    fun socketThatNeverOpensFailsTheHelper() = runTest {
        val s = session()
        val job = launch { s.run {} }
        assertEquals(starting, next())
        assertEquals(failed(MirrorReason.MIRROR_REASON_HELPER_FAILED), next())
        assertTrue(currentTime in 4_900..5_100, "gave up at $currentTime")
        job.join()
        assertEquals(1, dialer.links[0].closes.get())
    }

    @Test
    fun dummyByteIsForwarded() = runTest {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        next()
        assertEquals(running, next())
        val mac = dialer.link(BulkRole.BULK_ROLE_MIRROR_VIDEO)
        assertContentEquals(byteArrayOf(0), mac.toMac.readExactly(1))
        // Then the helper's stream, unchanged, and the Mac's control bytes reach the helper.
        video.fromHelper.output.write(byteArrayOf(9, 8, 7))
        assertContentEquals(byteArrayOf(9, 8, 7), mac.toMac.readExactly(3))
        dialer.link(BulkRole.BULK_ROLE_MIRROR_CONTROL).fromMac.output.write(byteArrayOf(2, 0, 1))
        assertContentEquals(byteArrayOf(2, 0, 1), control.toHelper.readExactly(3))
        s.stop(null)
        job.join()
    }

    @Test
    fun audioOffDialsTwoLinks() = runTest {
        planAll(audioOn = false)
        val s = session(start = mirrorStart(audio = false))
        val job = launch { s.run {} }
        next()
        assertEquals(running, next())
        assertEquals(listOf(BulkRole.BULK_ROLE_MIRROR_VIDEO, BulkRole.BULK_ROLE_MIRROR_CONTROL), dialer.links.map { it.role })
        assertEquals(2, adb.opens.count { it.startsWith("localabstract:") })
        assertTrue(" audio=false " in adb.opens.single { it.startsWith("shell:") })
        s.stop(null)
        job.join()
    }

    @Test
    fun macLinkEofStopsHelper() = runTest {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        next()
        assertEquals(running, next())
        dialer.link(BulkRole.BULK_ROLE_MIRROR_VIDEO).macCloses()
        assertEquals(failed(MirrorReason.MIRROR_REASON_LINK_FAILED), next())
        job.join()
        assertEquals(listOf(1, 1, 1, 1), listOf(video, audio, control, adb.shellStream).map { it.closes.get() })
        assertEquals(listOf(KILL, KILL), adb.shells.filter { it == KILL })
        assertEquals(KILL, adb.shells.last())
    }

    @Test
    fun macLinkEofAfterTheMacsStopIsStoppedUser() = runTest {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        next()
        assertEquals(running, next())
        // The link ends a moment before the Mac's mirror.stop is handled.
        dialer.link(BulkRole.BULK_ROLE_MIRROR_CONTROL).macCloses()
        Thread.sleep(50)
        s.stop(MirrorReason.MIRROR_REASON_USER, drainControl = true)
        assertEquals(stopped(MirrorReason.MIRROR_REASON_USER), next())
        job.join()
    }

    @Test
    fun stopDrainsTheMacControlLink() = runTest {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        next()
        assertEquals(running, next())
        val mac = dialer.link(BulkRole.BULK_ROLE_MIRROR_CONTROL)
        // The Mac's mirror.stop arrives first; its last bytes (screen on, the UP) follow on the link.
        val late = thread {
            Thread.sleep(100)
            mac.fromMac.output.write(byteArrayOf(10, 1))
            mac.macCloses()
        }
        s.stop(MirrorReason.MIRROR_REASON_USER, drainControl = true)
        assertEquals(stopped(MirrorReason.MIRROR_REASON_USER), next())
        job.join()
        late.join()
        assertContentEquals(byteArrayOf(10, 1), control.toHelper.readExactly(2))
    }

    private suspend fun TestScope.runningSession(): Pair<MirrorSession, kotlinx.coroutines.Job> {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        assertEquals(starting, next())
        assertEquals(running, next())
        return s to job
    }

    @Test
    fun stalledVideoWriteTripsLinkSlowAfterTwoSeconds() = runTest {
        val (_, job) = runningSession()
        val mac = dialer.link(BulkRole.BULK_ROLE_MIRROR_VIDEO)
        mac.stall()
        video.fromHelper.output.write(ByteArray(1_000))
        assertTrue(mac.writeEntered.await(5, TimeUnit.SECONDS))
        val since = currentTime
        advanceTimeBy(MirrorSession.MAX_WRITE_BLOCKED_MS - (currentTime - since))
        runCurrent()
        assertTrue(states.tryReceive().isFailure, "not at 2 s")
        advanceTimeBy(MirrorSession.WATCH_MS)
        assertEquals(failed(MirrorReason.MIRROR_REASON_LINK_SLOW), next())
        job.join()
        assertEquals(1, video.closes.get())
    }

    @Test
    fun stalledAudioWriteTripsLinkSlowToo() = runTest {
        val (_, job) = runningSession()
        val mac = dialer.link(BulkRole.BULK_ROLE_MIRROR_AUDIO)
        mac.stall()
        audio.fromHelper.output.write(ByteArray(100))
        assertTrue(mac.writeEntered.await(5, TimeUnit.SECONDS))
        advanceTimeBy(MirrorSession.MAX_WRITE_BLOCKED_MS)
        runCurrent()
        assertTrue(states.tryReceive().isFailure)
        advanceTimeBy(MirrorSession.WATCH_MS)
        assertEquals(failed(MirrorReason.MIRROR_REASON_LINK_SLOW), next())
        job.join()
    }

    @Test
    fun videoBacklogTripsAboveFourMiB() = runTest {
        val (_, job) = runningSession()
        video.queued = MirrorSession.MAX_VIDEO_QUEUED_BYTES
        audio.queued = MirrorSession.MAX_AUDIO_QUEUED_BYTES
        advanceTimeBy(10_000)
        runCurrent()
        assertTrue(states.tryReceive().isFailure, "at the limits")
        video.queued = MirrorSession.MAX_VIDEO_QUEUED_BYTES + 1
        advanceTimeBy(MirrorSession.WATCH_MS)
        runCurrent()
        assertEquals(failed(MirrorReason.MIRROR_REASON_LINK_SLOW), next())
        job.join()
    }

    @Test
    fun audioBacklogTripsAboveHalfMiB() = runTest {
        val (_, job) = runningSession()
        audio.queued = MirrorSession.MAX_AUDIO_QUEUED_BYTES + 1
        advanceTimeBy(MirrorSession.WATCH_MS)
        runCurrent()
        assertEquals(failed(MirrorReason.MIRROR_REASON_LINK_SLOW), next())
        job.join()
    }

    @Test
    fun unmeasurableBacklogNeverTrips() = runTest {
        val (s, job) = runningSession()
        video.queued = null
        audio.queued = null
        advanceTimeBy(60_000)
        runCurrent()
        assertTrue(states.tryReceive().isFailure)
        s.stop(null)
        job.join()
    }

    @Test
    fun helperExitReportsHelperFailed() = runTest {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        next()
        assertEquals(running, next())
        adb.shellStream.helperCloses()
        assertEquals(failed(MirrorReason.MIRROR_REASON_HELPER_FAILED), next())
        job.join()
        assertEquals(0, adbLost)
        assertEquals(1, video.closes.get())
    }

    @Test
    fun adbDropReportsAdbFailedAndNeedsSetup() = runTest {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        next()
        assertEquals(running, next())
        adb.isConnected = false
        listOf(video, audio, control, adb.shellStream).forEach { it.helperCloses() }
        assertEquals(failed(MirrorReason.MIRROR_REASON_ADB_FAILED), next())
        job.join()
        assertEquals(1, adbLost)
        assertEquals(1, adb.shells.count { it == KILL }) // only the one before launching
        assertTrue(dialer.links.all { it.closes.get() == 1 })
    }

    @Test
    fun connectFailureReportsItsReason() = runTest {
        val s = session(connect = { MirrorReason.MIRROR_REASON_NEEDS_SETUP })
        val job = launch { s.run {} }
        assertEquals(starting, next())
        assertEquals(failed(MirrorReason.MIRROR_REASON_NEEDS_SETUP), next())
        job.join()
        assertTrue(dialer.links.isEmpty())
        assertTrue(adb.shells.isEmpty())
    }

    @Test
    fun dialFailureIsLinkFailed() = runTest {
        val failing = FakeDialer(failOn = BulkRole.BULK_ROLE_MIRROR_CONTROL)
        val s = session(dialer = failing)
        val job = launch { s.run {} }
        assertEquals(starting, next())
        assertEquals(failed(MirrorReason.MIRROR_REASON_LINK_FAILED), next())
        job.join()
        assertTrue(failing.links.all { it.closes.get() == 1 })
        assertTrue(adb.opens.none { it.startsWith("shell:") })
    }

    @Test
    fun installFailureIsHelperFailed() = runTest {
        adb.shaLine = { "bad  x\n" }
        val s = session()
        val job = launch { s.run {} }
        assertEquals(starting, next())
        assertEquals(failed(MirrorReason.MIRROR_REASON_HELPER_FAILED), next())
        job.join()
        assertTrue(adb.opens.none { it.startsWith("shell:") })
    }

    @Test
    fun notRunningIn20sFails() = runTest {
        val s = session(connect = { awaitCancellation() })
        val job = launch { s.run {} }
        assertEquals(starting, next())
        assertEquals(failed(MirrorReason.MIRROR_REASON_HELPER_FAILED), next())
        assertEquals(20_000L, currentTime)
        job.join()
    }

    @Test
    fun stopClosesEverythingOnce() = runTest {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        next()
        assertEquals(running, next())
        s.stop(MirrorReason.MIRROR_REASON_USER)
        s.stop(MirrorReason.MIRROR_REASON_REPLACED)
        s.stop(null)
        assertEquals(stopped(MirrorReason.MIRROR_REASON_USER), next())
        job.join()
        assertTrue(states.tryReceive().isFailure, "one end state only")
        assertTrue(dialer.links.all { it.closes.get() == 1 })
        assertEquals(listOf(1, 1, 1, 1), listOf(video, audio, control, adb.shellStream).map { it.closes.get() })
        assertEquals(2, adb.shells.count { it == KILL })
    }

    @Test
    fun stopWhileStartingEndsAtOnce() = runTest {
        val s = session(connect = { awaitCancellation() })
        val job = launch { s.run {} }
        assertEquals(starting, next())
        s.stop(MirrorReason.MIRROR_REASON_REPLACED)
        assertEquals(stopped(MirrorReason.MIRROR_REASON_REPLACED), next())
        job.join()
        assertEquals(0L, currentTime)
    }

    @Test
    fun stopBeforeRunReportsOnlyTheEnd() = runTest {
        val s = session()
        s.stop(MirrorReason.MIRROR_REASON_REPLACED)
        s.run {}
        assertEquals(stopped(MirrorReason.MIRROR_REASON_REPLACED), next())
        assertTrue(states.tryReceive().isFailure)
        assertTrue(dialer.links.isEmpty())
        assertTrue(adb.opens.isEmpty() && adb.shells.isEmpty())
    }

    @Test
    fun disconnectStopReportsNothing() = runTest {
        planAll()
        val s = session()
        val job = launch { s.run {} }
        next()
        assertEquals(running, next())
        s.stop(null)
        job.join()
        assertTrue(states.tryReceive().isFailure)
        assertTrue(dialer.links.all { it.closes.get() == 1 })
    }
}
