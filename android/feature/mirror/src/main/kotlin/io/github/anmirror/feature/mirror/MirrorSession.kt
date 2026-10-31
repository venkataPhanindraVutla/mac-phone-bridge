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
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import kotlin.coroutines.CoroutineContext

/** Dials one of the session's bulk links to the connected Mac (SPEC 13), writing its `bulk.hello`. */
fun interface LinkDialer {
    suspend fun dial(role: BulkRole, token: ByteString): BulkStream
}

/**
 * Why a Full mode connect failed, for `mirror.state FAILED`: Wireless debugging is off, or the
 * pairing is gone (NEEDS_SETUP); otherwise it could not be reached (ADB_FAILED).
 */
fun connectFailureReason(wirelessDebugging: Boolean?, paired: Boolean): MirrorReason =
    if (wirelessDebugging == false || !paired) MirrorReason.MIRROR_REASON_NEEDS_SETUP else MirrorReason.MIRROR_REASON_ADB_FAILED

/**
 * One mirror session on the phone (SPEC 24): connects to the phone's own ADB ([connect]: null, or
 * the FAILED reason), dials the Mac's bulk links, pushes and launches the helper, opens its
 * sockets and relays them both ways with [RelayPump]s on their own threads, then waits for the end.
 *
 * Ends: [stop] (from the Mac, the phone, a newer start or a disconnect), a Mac link ending
 * (LINK_FAILED, unless the Mac's stop arrives within [LINK_END_GRACE_MS]), a helper pipe or the
 * shell ending (HELPER_FAILED; ADB_FAILED and [onAdbLost] when the ADB connection went with it),
 * or no RUNNING within [START_DEADLINE_MS]. Then the Mac links, the ADB pipes and the shell close,
 * once each, and `pkill` runs while ADB is up. [io] runs blocking reads; [log] gets IDs, phases,
 * reasons, role names and byte counts only.
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

    private val id = start.session

    override suspend fun run() {
        val began = clock()
        try {
            // Replaced (or the Mac gone) before it began: only the end is told.
            ended.takeIf { it.isCompleted }?.let { return finish(it.await(), began) }
            report(state(MirrorPhase.MIRROR_PHASE_STARTING))
            log("session $id start audio=${start.audio} codec=${start.videoCodec.name} max_size=${start.maxSize} fps=${start.maxFps}")
            val end = coroutineScope {
                val startUp = async { startUp() }
                val deadline = launch {
                    delay(START_DEADLINE_MS)
                    end(End.Failed(MirrorReason.MIRROR_REASON_HELPER_FAILED, "deadline"))
                }
                val ready = select {
                    ended.onAwait { false }
                    startUp.onAwait { it }
                }
                deadline.cancel()
                if (ready) {
                    log("session $id running after ${clock() - began} ms")
                    report(state(MirrorPhase.MIRROR_PHASE_RUNNING))
                } else {
                    // A start stuck in a blocking read gets out once its pipe is closed.
                    closeAll()
                    startUp.cancel()
                }
                ended.await()
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
                runCatching { link.setSendBufferBytes(SEND_BUFFER_BYTES) }
                links[role] = link
            }

            helperTouched = true
            try {
                adb.shell(ServerCommand.KILL_STALE)
                installer.install()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return fail(MirrorReason.MIRROR_REASON_HELPER_FAILED, "install ${e.javaClass.simpleName}")
            }
            val scid = newScid()
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

            relay(BulkRole.BULK_ROLE_MIRROR_VIDEO, macVideo, video)
            if (audio != null) relay(BulkRole.BULK_ROLE_MIRROR_AUDIO, links.getValue(BulkRole.BULK_ROLE_MIRROR_AUDIO), audio)
            relay(BulkRole.BULK_ROLE_MIRROR_CONTROL, links.getValue(BulkRole.BULK_ROLE_MIRROR_CONTROL), control)
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

    /** Two pumps per socket: helper → Mac, and Mac → helper. */
    private fun relay(role: BulkRole, link: BulkStream, pipe: AdbPipe) {
        val name = tag(role)
        pump("$name-up", from = Side.HELPER, to = Side.MAC) { RelayPump.run(pipe.input, link.output, it) }
        val down = pump("$name-down", from = Side.MAC, to = Side.HELPER) { RelayPump.run(link.input, pipe.output, it) }
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

    /** A Mac link ended: LINK_FAILED, unless the Mac's own stop (sent first, on the control channel) arrives meanwhile. */
    private fun onMacLinkEnded(name: String) {
        if (ended.isCompleted || !macLinkEnded.compareAndSet(false, true)) return
        log("session $id mac link ended $name")
        scope.launch {
            delay(LINK_END_GRACE_MS)
            end(End.Failed(MirrorReason.MIRROR_REASON_LINK_FAILED, "mac $name"))
        }
    }

    private suspend fun finish(end: End, began: Long) {
        // The Mac sends its last control bytes (the screen back on, a touch UP) right after its
        // stop and then closes the link: let them through to the helper first.
        if (end is End.Stopped && end.drain) controlDown?.let { t -> withContext(io) { t.join(CONTROL_DRAIN_MS) } }
        closeAll()
        var adbUp = adb.isConnected
        if (adbUp && helperTouched) adbUp = killStale()
        val adbLost = adbWasUp && !adbUp
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
        if (state?.reason == MirrorReason.MIRROR_REASON_ADB_FAILED && adbLost) onAdbLost()
        log("session $id ended ${state?.phase?.name ?: "quietly"} ${state?.reason?.name ?: ""} after ${clock() - began} ms")
        state?.let { report(it) }
    }

    /** `pkill` while ADB is up; false when that showed ADB is gone. */
    private suspend fun killStale(): Boolean = try {
        withTimeout(KILL_TIMEOUT_MS) { adb.shell(ServerCommand.KILL_STALE) }
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
        const val START_DEADLINE_MS = 20_000L
        const val OPEN_RETRY_MS = 100L
        const val OPEN_TRIES = 50
        const val SEND_BUFFER_BYTES = 262_144
        const val LINK_END_GRACE_MS = 1_000L
        const val CONTROL_DRAIN_MS = 500L
        const val KILL_TIMEOUT_MS = 5_000L
        private const val DISCARD_BYTES = 4_096
    }
}
