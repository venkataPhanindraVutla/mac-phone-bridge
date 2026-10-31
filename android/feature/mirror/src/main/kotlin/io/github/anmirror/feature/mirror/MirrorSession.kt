package io.github.anmirror.feature.mirror

import com.google.protobuf.ByteString
import io.github.anmirror.adb.AdbClient
import io.github.anmirror.adb.AdbPipe
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.MirrorPhase
import io.github.anmirror.protocol.v1.MirrorReason
import io.github.anmirror.protocol.v1.MirrorStart
import io.github.anmirror.protocol.v1.MirrorState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import kotlin.coroutines.CoroutineContext

/**
 * One mirror session on the phone (SPEC 24): connects to the phone's own ADB ([connect]: null, or
 * the FAILED reason), dials the Mac's bulk links, pushes and launches the helper, opens its
 * sockets and relays them both ways with [RelayPump]s on their own threads, then waits for the end.
 *
 * Ends: [stop] (from the Mac, the phone, a newer start or a disconnect), a Mac link ending
 * (LINK_FAILED, unless the Mac's stop arrives within [LINK_END_GRACE_MS]), a helper pipe or the
 * shell ending (HELPER_FAILED; ADB_FAILED and [onAdbLost] when the ADB connection went with it),
 * no RUNNING within [START_DEADLINE_MS] (18 s), or the Mac falling behind (LINK_SLOW, ruling R54:
 * libadb takes in the helper's output however slowly the Mac reads, so a watchdog ends the session
 * when more than about 3 s of video ([maxVideoQueuedBytes], ruling R57) or
 * [MAX_AUDIO_QUEUED_BYTES] of audio wait on the phone, or one write to the Mac is blocked longer
 * than [MAX_WRITE_BLOCKED_MS]). Then the end is reported, the Mac links, the ADB pipes (the jar
 * push among them) and the shell close, once each, and `pkill` runs while ADB is up ([finish]).
 * [io] runs blocking reads; [log] gets IDs, phases, reasons, role names and byte counts only.
 */
class MirrorSession(
    val start: MirrorStart,
    private val adb: AdbClient,
    private val installer: HelperInstaller,
    private val dialer: LinkDialer,
    private val clipboardAutosync: Boolean,
    private val version: String,
    private val report: suspend (MirrorState) -> Unit,
    private val scope: CoroutineScope,
    private val clock: () -> Long,
    private val connect: suspend () -> MirrorReason?,
    private val onAdbLost: () -> Unit,
    private val log: (String) -> Unit = {},
    private val io: CoroutineContext = Dispatchers.IO,
    private val newScid: () -> Int = { ServerCommand.newScid() },
) : MirrorRun {
    private sealed interface End {
        data class Stopped(val reason: MirrorReason?, val drain: Boolean) : End
        data class Failed(val reason: MirrorReason, val why: String) : End
        data class HelperGone(val why: String) : End
    }

    private enum class Side { MAC, HELPER }

    private val ended = CompletableDeferred<End>()
    private val macLinks = CloseGroup()
    private val adbPipes = CloseGroup()
    private val shellPipe = CloseGroup()
    private val macLinkEnded = AtomicBoolean(false)

    /** The ADB connection was up for this session (so losing it is news). */
    @Volatile private var adbWasUp = false

    /** The helper was touched (stale ones killed): kill again at the end. */
    @Volatile private var helperTouched = false

    /** The Mac → helper control pump, which a Mac's stop lets finish. */
    @Volatile private var controlDown: Thread? = null

    /** A helper → Mac stream the watchdog keeps an eye on. */
    private class Watched(val name: String, val pipe: AdbPipe, val meter: RelayPump.WriteMeter, val maxQueued: Long)

    private val watched = java.util.concurrent.CopyOnWriteArrayList<Watched>()

    private val id = start.session

    override suspend fun run(awaitPrevious: suspend () -> Unit) {
        val began = clock()
        try {
            // Replaced (or the Mac gone) before it began: only the end is told.
            ended.takeIf { it.isCompleted }?.let { return finish(it.await(), began) }
            report(state(MirrorPhase.MIRROR_PHASE_STARTING))
            log("session $id start audio=${start.audio} codec=${start.videoCodec.name} max_size=${start.maxSize} fps=${start.maxFps}")
            val end = coroutineScope {
                // The wait for the session this one replaces counts against the deadline (the Mac's started at its start).
                val startUp = async {
                    awaitPrevious()
                    startUp()
                }
                val deadline = launch {
                    delay(START_DEADLINE_MS)
                    end(End.Failed(MirrorReason.MIRROR_REASON_HELPER_FAILED, "deadline"))
                }
                val ready = select {
                    ended.onAwait { false }
                    startUp.onAwait { it }
                }
                deadline.cancel()
                var watchdog: Job? = null
                if (ready) {
                    log("session $id running after ${clock() - began} ms")
                    report(state(MirrorPhase.MIRROR_PHASE_RUNNING))
                    watchdog = launch { watch() }
                } else {
                    // The end goes to the Mac first (R59); then a start stuck in a blocking read
                    // gets out once its pipe is closed.
                    tellEnd(ended.await(), began)
                    closeAll()
                    startUp.cancel()
                }
                ended.await().also { watchdog?.cancel() }
            }
            finish(end, began)
        } finally {
            closeAll()
        }
    }

    /** Idempotent; the first end wins. [reason] null (a disconnect) reports nothing. */
    override fun stop(reason: MirrorReason?, drainControl: Boolean) {
        end(End.Stopped(reason, drainControl))
    }

    private fun end(e: End) {
        if (ended.complete(e)) log("session $id ending ${describe(e)}")
    }

    private fun fail(reason: MirrorReason, why: String): Boolean {
        end(End.Failed(reason, why))
        return false
    }

    /** True once every socket is relayed; false after an end (already recorded). */
    private suspend fun startUp(): Boolean {
        try {
            connect()?.let { return fail(it, "connect") }
            adbWasUp = true
            val links = mutableMapOf<BulkRole, BulkStream>()
            for ((role, token) in linkTokens()) {
                val link = try {
                    dialer.dial(role, token)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    return fail(MirrorReason.MIRROR_REASON_LINK_FAILED, "dial ${tag(role)} ${e.javaClass.simpleName}")
                }
                if (!macLinks.add(link)) return false
                try {
                    link.setSendBufferBytes(SEND_BUFFER_BYTES)
                } catch (e: Exception) {
                    log("session $id ${tag(role)} send buffer not set ${e.javaClass.simpleName}")
                }
                links[role] = link
            }

            helperTouched = true
            val scid = newScid()
            try {
                adb.shell(ServerCommand.killStale(version))
                // The push joins the ADB pipes, so an end closes it even if adbd stops answering (M4).
                installer.install(ServerCommand.jarPath(scid), adbPipes::add)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return fail(MirrorReason.MIRROR_REASON_HELPER_FAILED, "install ${e.javaClass.simpleName}")
            }
            val command = ServerCommand.build(HelperOptions.from(start, scid, clipboardAutosync), version)
            val shell = try {
                adb.open("shell:$command")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return fail(MirrorReason.MIRROR_REASON_HELPER_FAILED, "launch ${e.javaClass.simpleName}")
            }
            if (!shellPipe.add(shell)) return false
            // The helper's output is read (so it never blocks on a full pipe) and dropped, never logged.
            thread(isDaemon = true, name = "mirror-shell") {
                discard(shell.input)
                end(End.HelperGone("shell"))
            }

            val socket = "localabstract:" + ServerCommand.socketName(scid)
            val (video, dummy) = openSocket(socket, firstByte = true)
                ?: return fail(MirrorReason.MIRROR_REASON_HELPER_FAILED, "video socket")
            val macVideo = links.getValue(BulkRole.BULK_ROLE_MIRROR_VIDEO)
            try {
                withContext(io) {
                    macVideo.output.write(dummy)
                    macVideo.output.flush()
                }
            } catch (e: IOException) {
                return fail(MirrorReason.MIRROR_REASON_LINK_FAILED, "video link")
            }
            val audio = if (start.audio) {
                openSocket(socket, firstByte = false)?.first ?: return fail(MirrorReason.MIRROR_REASON_HELPER_FAILED, "audio socket")
            } else {
                null
            }
            val control = openSocket(socket, firstByte = false)?.first
                ?: return fail(MirrorReason.MIRROR_REASON_HELPER_FAILED, "control socket")

            relay(BulkRole.BULK_ROLE_MIRROR_VIDEO, macVideo, video, maxVideoQueuedBytes(start.videoBitRate))
            if (audio != null) relay(BulkRole.BULK_ROLE_MIRROR_AUDIO, links.getValue(BulkRole.BULK_ROLE_MIRROR_AUDIO), audio, MAX_AUDIO_QUEUED_BYTES)
            relay(BulkRole.BULK_ROLE_MIRROR_CONTROL, links.getValue(BulkRole.BULK_ROLE_MIRROR_CONTROL), control, maxQueued = null)
            return !ended.isCompleted
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return fail(MirrorReason.MIRROR_REASON_HELPER_FAILED, "start ${e.javaClass.simpleName}")
        }
    }

    private fun linkTokens(): List<Pair<BulkRole, ByteString>> = buildList {
        add(BulkRole.BULK_ROLE_MIRROR_VIDEO to start.tokens.video)
        if (start.audio) add(BulkRole.BULK_ROLE_MIRROR_AUDIO to start.tokens.audio)
        add(BulkRole.BULK_ROLE_MIRROR_CONTROL to start.tokens.control)
    }

    /**
     * Opens the helper's socket, every [OPEN_RETRY_MS] for [OPEN_TRIES] tries (nothing listens
     * until the helper is up). With [firstByte] it counts as open once its first byte (the dummy
     * byte) is read, which is returned; -1 otherwise. Null when it never opened, or on an end.
     */
    private suspend fun openSocket(service: String, firstByte: Boolean): Pair<AdbPipe, Int>? {
        repeat(OPEN_TRIES) { attempt ->
            if (ended.isCompleted) return null
            if (attempt > 0) delay(OPEN_RETRY_MS)
            val pipe = try {
                adb.open(service)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
            if (pipe != null) {
                if (!adbPipes.add(pipe)) return null
                if (!firstByte) return pipe to -1
                val b = try {
                    withContext(io) { pipe.input.read() }
                } catch (e: IOException) {
                    -1
                }
                if (b >= 0) return pipe to b
                adbPipes.remove(pipe)
                pipe.close()
            }
        }
        return null
    }

    /**
     * Two pumps per socket: helper → Mac, and Mac → helper. With [maxQueued], the watchdog watches
     * the helper → Mac side (the control socket's few device messages are not watched).
     */
    private fun relay(role: BulkRole, link: BulkStream, pipe: AdbPipe, maxQueued: Long?) {
        val name = tag(role)
        val meter = RelayPump.WriteMeter(clock)
        if (maxQueued != null) watched += Watched(name, pipe, meter, maxQueued)
        pump("$name-up", from = Side.HELPER, to = Side.MAC) { RelayPump.run(pipe.input, link.output, meter, it) }
        val down = pump("$name-down", from = Side.MAC, to = Side.HELPER) { RelayPump.run(link.input, pipe.output, onEnd = it) }
        if (role == BulkRole.BULK_ROLE_MIRROR_CONTROL) controlDown = down
    }

    /** Runs [body] on its own thread; its end is the [from] side ending, or the [to] side on a failed write. */
    private fun pump(name: String, from: Side, to: Side, body: ((Throwable?) -> Unit) -> Long): Thread =
        thread(isDaemon = true, name = "mirror-$name") {
            val bytes = body { e ->
                val side = if (e is RelayPump.WriteFailed) to else from
                if (side == Side.MAC) onMacLinkEnded(name) else end(End.HelperGone(name))
            }
            log("session $id relay $name bytes=$bytes")
        }

    /**
     * Every [WATCH_MS] while RUNNING: LINK_SLOW once a watched stream has more queued on the phone
     * than its limit, or its write to the Mac has been blocked longer than [MAX_WRITE_BLOCKED_MS].
     * A stream whose queue can't be measured is watched by the write time alone.
     */
    private suspend fun watch() {
        while (true) {
            delay(WATCH_MS)
            for (w in watched) {
                val queued = runCatching { w.pipe.queuedBytes() }.getOrNull() ?: 0L
                val blocked = w.meter.blockedMs()
                if (queued > w.maxQueued || blocked > MAX_WRITE_BLOCKED_MS) {
                    end(End.Failed(MirrorReason.MIRROR_REASON_LINK_SLOW, "${w.name} queued=$queued blocked=${blocked}ms"))
                    return
                }
            }
        }
    }

    /** A Mac link ended: LINK_FAILED, unless the Mac's own stop (sent first, on the control channel) arrives meanwhile. */
    private fun onMacLinkEnded(name: String) {
        if (ended.isCompleted || !macLinkEnded.compareAndSet(false, true)) return
        log("session $id mac link ended $name")
        scope.launch {
            delay(LINK_END_GRACE_MS)
            end(End.Failed(MirrorReason.MIRROR_REASON_LINK_FAILED, "mac $name"))
        }
    }

    /**
     * The end, in this order (ruling R59): the reason to the Mac first ([tellEnd]), while its links
     * are still open (a link end becomes LINK_FAILED on the Mac after its 1 s grace) and before
     * `pkill` (up to [KILL_TIMEOUT_MS]); then the Mac's last control bytes (after its own stop), the
     * links and pipes, and `pkill`. When only `pkill` shows ADB gone after a helper failure,
     * [onAdbLost] still runs (the reason sent stays HELPER_FAILED).
     */
    private suspend fun finish(end: End, began: Long) {
        tellEnd(end, began)
        // The Mac sends its last control bytes (the screen back on, a touch UP) right after its
        // stop and then closes the link: let them through to the helper first.
        if (end is End.Stopped && end.drain) controlDown?.let { t -> withContext(io) { t.join(CONTROL_DRAIN_MS) } }
        closeAll()
        var adbUp = adb.isConnected
        if (adbUp && helperTouched) adbUp = killStale()
        val reason = endState?.reason
        val helperEnd = reason == MirrorReason.MIRROR_REASON_HELPER_FAILED || reason == MirrorReason.MIRROR_REASON_ADB_FAILED
        if (helperEnd && adbWasUp && !adbUp) onAdbLost()
    }

    /** The state [tellEnd] sent; null when it sent nothing (a disconnect) or has not run. */
    @Volatile private var endState: MirrorState? = null
    private val endTold = AtomicBoolean(false)

    /** Works out the end's state and sends it, once. Whether ADB was lost is judged now, before `pkill`. */
    private suspend fun tellEnd(end: End, began: Long) {
        if (!endTold.compareAndSet(false, true)) return
        val adbLost = adbWasUp && !adb.isConnected
        val state = when (end) {
            is End.Stopped -> end.reason?.let { state(MirrorPhase.MIRROR_PHASE_STOPPED, it) }
            is End.Failed -> state(
                MirrorPhase.MIRROR_PHASE_FAILED,
                if (end.reason == MirrorReason.MIRROR_REASON_HELPER_FAILED && adbLost) MirrorReason.MIRROR_REASON_ADB_FAILED else end.reason,
            )
            is End.HelperGone -> state(
                MirrorPhase.MIRROR_PHASE_FAILED,
                if (adbLost) MirrorReason.MIRROR_REASON_ADB_FAILED else MirrorReason.MIRROR_REASON_HELPER_FAILED,
            )
        }
        endState = state
        log("session $id ended ${state?.phase?.name ?: "quietly"} ${state?.reason?.name ?: ""} after ${clock() - began} ms")
        state?.let { tell(it) }
    }

    /** Reports [state], waiting at most [REPORT_WAIT_MS]: a stuck control connection must not keep the links open. */
    private suspend fun tell(state: MirrorState) {
        val told = scope.launch { report(state) }
        withTimeoutOrNull(REPORT_WAIT_MS) { told.join() }
    }

    /** `pkill` while ADB is up; false when that showed ADB is gone. */
    private suspend fun killStale(): Boolean = try {
        withTimeout(KILL_TIMEOUT_MS) { adb.shell(ServerCommand.killStale(version)) }
        true
    } catch (e: TimeoutCancellationException) {
        adb.isConnected
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        adb.isConnected
    }

    /** The Mac links, then the ADB pipes, then the shell stream; each once. */
    private fun closeAll() {
        macLinks.close()
        adbPipes.close()
        shellPipe.close()
    }

    private fun state(phase: MirrorPhase, reason: MirrorReason = MirrorReason.MIRROR_REASON_UNSPECIFIED): MirrorState =
        MirrorState.newBuilder().setSession(id).setPhase(phase).setReason(reason).build()

    private fun describe(e: End): String = when (e) {
        is End.Stopped -> "stopped ${e.reason?.name ?: "disconnect"}"
        is End.Failed -> "failed ${e.reason.name} (${e.why})"
        is End.HelperGone -> "helper side ended (${e.why})"
    }

    private fun tag(role: BulkRole) = role.name.removePrefix("BULK_ROLE_MIRROR_").lowercase()

    private fun discard(input: InputStream) {
        val buffer = ByteArray(DISCARD_BYTES)
        try {
            do {
                val n = input.read(buffer)
            } while (n >= 0)
        } catch (e: IOException) {
            // closed: the shell stream ended
        }
    }

    /** Closeables closed together, each once; one added after [close] is closed at once. */
    private class CloseGroup {
        private val items = mutableListOf<Closeable>()
        private var closed = false

        fun add(c: Closeable): Boolean {
            synchronized(this) {
                if (!closed) {
                    items += c
                    return true
                }
            }
            runCatching { c.close() }
            return false
        }

        fun remove(c: Closeable) = synchronized(this) { items.remove(c) }

        fun close() {
            val all = synchronized(this) {
                closed = true
                items.toList().also { items.clear() }
            }
            all.forEach { runCatching { it.close() } }
        }
    }

    companion object {
        /** Inside the Mac's 20 s (to RUNNING and a first frame), so the phone's reason reaches the Mac first (R59). */
        const val START_DEADLINE_MS = 18_000L
        const val OPEN_RETRY_MS = 100L
        const val OPEN_TRIES = 50
        const val SEND_BUFFER_BYTES = 262_144
        const val LINK_END_GRACE_MS = 1_000L
        const val CONTROL_DRAIN_MS = 500L
        const val KILL_TIMEOUT_MS = 5_000L
        const val REPORT_WAIT_MS = 1_000L
        const val WATCH_MS = 100L
        const val MIN_VIDEO_QUEUED_BYTES = 512L * 1024
        const val MAX_VIDEO_QUEUED_BYTES = 4L * 1024 * 1024
        const val MAX_AUDIO_QUEUED_BYTES = 512L * 1024
        const val MAX_WRITE_BLOCKED_MS = 2_000L
        private const val DISCARD_BYTES = 4_096
        private const val VIDEO_BACKLOG_SECONDS = 3L

        /**
         * Ruling R57: the video backlog that ends a session is about 3 s of video at the session's
         * bit rate (a uint32), within [MIN_VIDEO_QUEUED_BYTES]…[MAX_VIDEO_QUEUED_BYTES]. So the
         * picture can't trail far behind at Low, and Auto (which steps down with far less queued)
         * still acts first at every preset.
         */
        fun maxVideoQueuedBytes(videoBitRate: Int): Long =
            (Integer.toUnsignedLong(videoBitRate) / 8 * VIDEO_BACKLOG_SECONDS).coerceIn(MIN_VIDEO_QUEUED_BYTES, MAX_VIDEO_QUEUED_BYTES)
    }
}
