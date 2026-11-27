package io.github.anmirror.transfer

import com.google.protobuf.ByteString
import com.google.protobuf.InvalidProtocolBufferException
import com.google.protobuf.MessageLite
import io.github.anmirror.connection.BULK_BUFFER_BYTES
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.TransferAccept
import io.github.anmirror.protocol.v1.TransferCancel
import io.github.anmirror.protocol.v1.TransferComplete
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferFailed
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.protocol.v1.TransferOffer
import io.github.anmirror.protocol.v1.TransferProgress
import io.github.anmirror.protocol.v1.TransferReceived
import io.github.anmirror.protocol.v1.TransferReject
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.cancellation.CancellationException

/**
 * Phone side of SPEC 16 transfers: runs `files.*` control messages and the bulk bytes behind
 * them. One SEND and one RECEIVE run at a time; more wait in order. File I/O runs on [io].
 * Logs carry IDs, sizes, durations and error codes only, never names or content.
 *
 * Resume (files.resume.v1, SPEC 16; [resumes] says whether the Mac in session shares it): a
 * send of a file that [OutgoingFile.canResume] which breaks (INTERRUPTED, TIMED_OUT) is
 * [TransferState.PAUSED] and offered again with the same ID, at once when the same Mac
 * connects again ([onConnected]) or after a growing delay while connected; a resumable receive
 * that breaks keeps its bytes ([IncomingFile.keep]) and the Mac's next offer of it goes on
 * from there ([IncomingSinks.resume]). Both give up after [TransferTiming.keepPausedMs].
 * Paused sends live in this process only.
 */
class TransferEngine(
    private val scope: CoroutineScope,
    private val send: suspend (type: String, payload: MessageLite) -> Boolean,
    private val bulk: BulkOpener,
    private val sinks: IncomingSinks,
    private val freeBytes: (TransferOffer) -> Long?, // null = unknown, accept
    private val clock: () -> Long = System::currentTimeMillis,
    private val newId: () -> String = { UUID.randomUUID().toString() },
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val timing: TransferTiming = TransferTiming(),
    private val resumes: () -> Boolean = { false },
) {
    private sealed interface Reply {
        class Accepted(val token: ByteString, val offset: Long) : Reply
        class Rejected(val reason: TransferError) : Reply
        object Received : Reply
        object Aborted : Reply
    }

    private enum class Notify { NONE, CANCEL, FAILED }

    private class Abort(val reason: TransferError, val notify: Notify)

    private sealed interface Outcome {
        class Done(val savedAs: String?) : Outcome
        class Fail(val reason: TransferError, val notify: Notify) : Outcome
    }

    /** The local file or sink broke, as opposed to the connection. */
    private class LocalFault(cause: Throwable?) : IOException(cause)

    /** The bulk stream ended before the announced size. */
    private class EarlyEnd : IOException()

    private class Xfer(
        val id: String,
        val direction: Direction,
        initial: TransferStatus,
        val requestId: Long,
        /** What a send reads, kept to offer it again after a pause. */
        val file: OutgoingFile? = null,
        /** When this transfer first paused (wall clock), and the retry delay last used. */
        val pausedSince: Long = 0,
        val retryMs: Long = 0,
    ) {
        @Volatile var status = initial
        /** Offered as resumable (send), or received from a resumable offer with resume shared (receive). */
        @Volatile var resumable = false
        /** Bytes the receiver already had. */
        @Volatile var offset = 0L
        @Volatile var started = false
        @Volatile var final = false
        @Volatile var peerKnows = direction == Direction.RECEIVE
        @Volatile var stream: BulkStream? = null
        @Volatile var sink: IncomingFile? = null
        @Volatile var lastTick = 0L
        @Volatile var lateDial = false
        val pendingDial = AtomicReference<BulkStream?>(null)
        val concluded = AtomicBoolean(false)
        val sinkClaimed = AtomicBoolean(false)
        val abort = AtomicReference<Abort?>(null)
        val moved = AtomicLong(0)
        val startedAt = System.nanoTime()
        val reply = CompletableDeferred<Reply>()           // SEND: accept or reject, then received
        val received = CompletableDeferred<Reply>()
        val interrupted = CompletableDeferred<Unit>()      // completes on interrupt, wakes a dial
        val complete = CompletableDeferred<ByteArray?>()   // RECEIVE: the sender's hash; null when aborted
    }

    private val lock = Any()
    private val live = LinkedHashMap<String, Xfer>()

    /** A send waiting to be offered again, and the Mac it is for. */
    private class Paused(val x: Xfer, val kind: TransferKind, val peer: String?)

    private val paused = LinkedHashMap<String, Paused>()

    /** A receive whose bytes the sink kept, waiting for the Mac's next offer. */
    private class Kept(val name: String, val size: Long, val at: Long)

    private val kept = HashMap<String, Kept>()

    /** The Mac in session (its ID), and whether it shared files.resume.v1 when it connected. */
    @Volatile private var peer: String? = null
    @Volatile private var connected = false
    @Volatile private var peerResumes = false
    private val finished = ArrayDeque<TransferStatus>() // most recent first
    private val state = MutableStateFlow<List<TransferStatus>>(emptyList())

    /** Active and queued transfers first, then the last 20 finished. */
    val transfers: StateFlow<List<TransferStatus>> = state.asStateFlow()

    private class QueuedWork(val x: Xfer, val run: suspend () -> Unit)

    private val sendJobs = Channel<QueuedWork>(Channel.UNLIMITED)
    private val receiveJobs = Channel<QueuedWork>(Channel.UNLIMITED)

    init {
        for (queue in listOf(sendJobs, receiveJobs)) {
            scope.launch {
                for (job in queue) {
                    try {
                        job.run()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        log("${job.x.id} crashed ${e.javaClass.simpleName}")
                    }
                }
            }
        }
    }

    fun send(
        files: List<OutgoingFile>,
        kind: TransferKind = TransferKind.TRANSFER_KIND_FILE,
        requestId: Long = 0,
    ): List<String> = files.map { f ->
        val id = newId()
        val x = Xfer(
            id, Direction.SEND,
            TransferStatus(id, Direction.SEND, f.name, f.size, 0, kind, TransferState.QUEUED, requestId = requestId),
            requestId, file = f,
        )
        register(x)
        sendJobs.trySend(QueuedWork(x) { runSend(x, f, kind) })
        id
    }

    fun cancel(id: String) {
        val x = synchronized(lock) { live[id] }
        if (x != null) return stop(x, TransferError.TRANSFER_ERROR_CANCELLED, Notify.CANCEL)
        // Paused, either way: it ends for good, and the Mac drops what it kept.
        if (endPaused(id, TransferState.CANCELLED, TransferError.TRANSFER_ERROR_CANCELLED) && connected) {
            scope.launch { send(MessageType.FILES_CANCEL, TransferCancel.newBuilder().setTransferId(id).build()) }
        }
    }

    /**
     * A session with Mac [peerId] began; [resumesNow] is whether it shares files.resume.v1.
     * Paused sends for it go again now; those for another Mac, or with resume no longer shared, end.
     */
    fun onConnected(peerId: String, resumesNow: Boolean) {
        peer = peerId
        peerResumes = resumesNow
        connected = true
        expire()
        val ids = synchronized(lock) { paused.keys.toList() }
        for (id in ids) {
            val p = synchronized(lock) { paused[id] } ?: continue
            if (p.peer == peerId && resumesNow) {
                requeue(id)
            } else {
                endPaused(id, TransferState.FAILED, TransferError.TRANSFER_ERROR_INTERRUPTED)
            }
        }
    }

    /** Handles `files.*` control messages. False for every other type. */
    suspend fun onMessage(env: Envelope): Boolean {
        try {
            when (env.type) {
                MessageType.FILES_OFFER -> onOffer(TransferOffer.parseFrom(env.payload))
                MessageType.FILES_ACCEPT -> TransferAccept.parseFrom(env.payload).let { m ->
                    peer(m.transferId, Direction.SEND)?.reply?.complete(Reply.Accepted(m.token, m.offset))
                }
                MessageType.FILES_REJECT -> TransferReject.parseFrom(env.payload).let { m ->
                    peer(m.transferId, Direction.SEND)?.reply?.complete(Reply.Rejected(m.reason.orInterrupted()))
                }
                MessageType.FILES_PROGRESS -> Unit // the sender tracks its own bytes
                MessageType.FILES_COMPLETE -> TransferComplete.parseFrom(env.payload).let { m ->
                    peer(m.transferId, Direction.RECEIVE)?.complete?.complete(m.sha256.toByteArray())
                }
                MessageType.FILES_RECEIVED -> TransferReceived.parseFrom(env.payload).let { m ->
                    peer(m.transferId, Direction.SEND)?.received?.complete(Reply.Received)
                }
                MessageType.FILES_CANCEL -> TransferCancel.parseFrom(env.payload).let { m ->
                    peer(m.transferId, null)?.let { stop(it, TransferError.TRANSFER_ERROR_CANCELLED, Notify.NONE) }
                        ?: endPaused(m.transferId, TransferState.CANCELLED, TransferError.TRANSFER_ERROR_CANCELLED)
                }
                MessageType.FILES_FAILED -> TransferFailed.parseFrom(env.payload).let { m ->
                    peer(m.transferId, null)?.let { stop(it, m.reason.orInterrupted(), Notify.NONE) }
                }
                else -> return false
            }
        } catch (e: InvalidProtocolBufferException) {
            log("bad ${env.type} payload")
        }
        return true
    }

    /**
     * The control connection is gone: every unfinished transfer fails INTERRUPTED, or pauses
     * (see the class doc). Nothing is sent.
     */
    fun onDisconnected() {
        connected = false
        val all = synchronized(lock) { live.values.toList() }
        for (x in all) stop(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.NONE)
    }

    // ---- resume ------------------------------------------------------------------------------

    private fun pausable(reason: TransferError?) =
        reason == TransferError.TRANSFER_ERROR_INTERRUPTED || reason == TransferError.TRANSFER_ERROR_TIMED_OUT

    /** A send that may pause: offered resumable, or queued and never offered while the Mac resumes. */
    private fun mayPause(x: Xfer): Boolean {
        val f = x.file ?: return false
        return x.direction == Direction.SEND && f.canResume && x.requestId == 0L &&
            x.status.kind == TransferKind.TRANSFER_KIND_FILE && (x.resumable || (!x.started && peerResumes))
    }

    /** Under [lock]: [x] ended broken; it waits to be offered again. */
    private fun pauseLocked(x: Xfer) {
        val since = if (x.pausedSince != 0L) x.pausedSince else clock()
        val delay = if (x.retryMs == 0L) timing.firstRetryMs else minOf(x.retryMs * 2, timing.maxRetryMs)
        val waiting = Xfer(
            x.id, Direction.SEND, x.status.copy(state = TransferState.PAUSED), 0,
            file = x.file, pausedSince = since, retryMs = delay,
        )
        waiting.resumable = true
        paused[x.id] = Paused(waiting, x.status.kind, peer)
        log("${x.id} paused after ${x.moved.get()} bytes")
        if (connected) {
            scope.launch {
                delay(delay)
                if (connected) requeue(x.id)
            }
        }
    }

    /** Offers paused send [id] again (same ID), unless it is past [TransferTiming.keepPausedMs]. */
    private fun requeue(id: String) {
        val p = synchronized(lock) { paused[id] } ?: return
        if (clock() - p.x.pausedSince > timing.keepPausedMs) {
            endPaused(id, TransferState.FAILED, TransferError.TRANSFER_ERROR_INTERRUPTED)
            return
        }
        val x = Xfer(
            id, Direction.SEND, p.x.status.copy(state = TransferState.QUEUED), 0,
            file = p.x.file, pausedSince = p.x.pausedSince, retryMs = p.x.retryMs,
        )
        synchronized(lock) {
            if (paused.remove(id) == null || live.containsKey(id)) return
            live[id] = x
            publish()
        }
        sendJobs.trySend(QueuedWork(x) { runSend(x, x.file!!, p.kind) })
    }

    /** Ends a paused send, or a kept receive, as [st]. False when [id] is neither. */
    private fun endPaused(id: String, st: TransferState, error: TransferError): Boolean {
        val wasKept = synchronized(lock) {
            val p = paused.remove(id)
            if (p != null) {
                finished.addFirst(p.x.status.copy(state = st, error = error))
                while (finished.size > KEEP_FINISHED) finished.removeLast()
                publish()
                return true
            }
            val k = kept.remove(id) ?: return false
            val i = finished.indexOfFirst { it.id == id && it.state == TransferState.PAUSED }
            if (i >= 0) finished[i] = finished[i].copy(state = st, error = error)
            publish()
            k
        }
        scope.launch(io) { runCatching { sinks.discard(id) } }
        log("$id ended paused (${wasKept.size} bytes kept) $st")
        return true
    }

    /** Kept receives past [TransferTiming.keepPausedMs] go. */
    private fun expire() {
        val old = synchronized(lock) { kept.filterValues { clock() - it.at > timing.keepPausedMs }.keys.toList() }
        for (id in old) endPaused(id, TransferState.FAILED, TransferError.TRANSFER_ERROR_INTERRUPTED)
    }

    // ---- bookkeeping -------------------------------------------------------------------------

    private fun peer(id: String, dir: Direction?): Xfer? =
        synchronized(lock) { live[id] }?.takeIf { dir == null || it.direction == dir }

    private fun register(x: Xfer) = synchronized(lock) {
        live[x.id] = x
        publish()
    }

    private fun publish() {
        state.value = live.values.map { it.status } + paused.values.map { it.x.status } + finished
    }

    private fun update(x: Xfer, f: (TransferStatus) -> TransferStatus) = synchronized(lock) {
        if (x.final) return@synchronized
        x.status = f(x.status)
        publish()
    }

    private fun finish(x: Xfer, st: TransferState, error: TransferError?, savedAs: String? = null) = synchronized(lock) {
        if (x.final) return@synchronized
        x.final = true
        if (st == TransferState.FAILED && pausable(error) && mayPause(x)) {
            live.remove(x.id)
            pauseLocked(x)
            publish()
            return@synchronized
        }
        x.status = x.status.copy(
            state = st, error = error, savedAs = savedAs,
            done = if (st == TransferState.DONE) x.status.size else x.status.done,
        )
        live.remove(x.id)
        finished.addFirst(x.status)
        while (finished.size > KEEP_FINISHED) finished.removeLast()
        publish()
    }

    // ---- stopping ----------------------------------------------------------------------------

    /** First reason wins: closes the stream and wakes every waiter. */
    private fun interrupt(x: Xfer, reason: TransferError, notify: Notify) {
        if (!x.abort.compareAndSet(null, Abort(reason, notify))) return
        // Closing a socket may block: never on the caller's thread (cancel() comes from the UI).
        x.stream?.let { s -> scope.launch(io) { runCatching { s.close() } } }
        x.interrupted.complete(Unit)
        x.reply.complete(Reply.Aborted)
        x.received.complete(Reply.Aborted)
        x.complete.complete(null)
    }

    /**
     * [interrupt], and for a transfer whose worker has not begun, finishes it right here. A send
     * answering a Mac request (`request_id` set) that is stopped here before its offer went says
     * `files.failed` with that request ID, so the Mac does not wait out its deadline. Nothing is
     * sent when the peer itself ended it ([Notify.NONE]: a disconnect, its cancel or failure).
     */
    private fun stop(x: Xfer, reason: TransferError, notify: Notify) {
        interrupt(x, reason, notify)
        if (!x.started && x.concluded.compareAndSet(false, true)) {
            val abort = x.abort.get()!!
            finish(x, stateFor(abort.reason), abort.reason)
            if (abort.notify != Notify.NONE && x.peerKnows) {
                scope.launch { notifyPeer(x, abort.notify, abort.reason) }
            } else if (abort.notify != Notify.NONE && x.direction == Direction.SEND && x.requestId != 0L) {
                scope.launch { notifyPeer(x, Notify.FAILED, abort.reason) }
            }
        }
    }

    private fun stateFor(reason: TransferError) =
        if (reason == TransferError.TRANSFER_ERROR_CANCELLED) TransferState.CANCELLED else TransferState.FAILED

    private fun fail(x: Xfer, reason: TransferError, notify: Notify): Outcome.Fail =
        x.abort.get()?.let { Outcome.Fail(it.reason, it.notify) } ?: Outcome.Fail(reason, notify)

    private suspend fun notifyPeer(x: Xfer, notify: Notify, reason: TransferError) {
        when (notify) {
            Notify.NONE -> Unit
            Notify.CANCEL -> send(MessageType.FILES_CANCEL, TransferCancel.newBuilder().setTransferId(x.id).build())
            Notify.FAILED -> send(
                MessageType.FILES_FAILED,
                TransferFailed.newBuilder().setTransferId(x.id).setReason(reason).setRequestId(x.requestId).build(),
            )
        }
    }

    /** A resumable receive that broke after writing bytes keeps them, when its sink can. */
    private suspend fun keepSink(x: Xfer, reason: TransferError): Boolean {
        val s = x.sink ?: return false
        if (x.direction != Direction.RECEIVE || !x.resumable || !pausable(reason) || x.offset + x.moved.get() == 0L) return false
        if (!x.sinkClaimed.compareAndSet(false, true)) return false
        val ok = withContext(io) { runCatching { s.keep() }.getOrDefault(false) }
        if (!ok) withContext(io) { runCatching { s.abort() } }
        return ok
    }

    private suspend fun abortSink(x: Xfer) {
        val s = x.sink ?: return
        if (!x.sinkClaimed.compareAndSet(false, true)) return
        withContext(io) { runCatching { s.abort() } }
    }

    /** Ends a transfer exactly once: stream closed, sink aborted, peer told, status final. */
    private suspend fun conclude(x: Xfer, outcome: Outcome) = withContext(NonCancellable) {
        if (!x.concluded.compareAndSet(false, true)) return@withContext
        x.stream?.let { runCatching { it.close() } }
        val ms = (System.nanoTime() - x.startedAt) / 1_000_000
        when (outcome) {
            is Outcome.Done -> {
                log("${x.id} done ${x.status.direction} ${x.status.size} bytes in $ms ms")
                finish(x, TransferState.DONE, null, outcome.savedAs)
            }
            is Outcome.Fail -> {
                val keptPart = keepSink(x, outcome.reason)
                if (!keptPart) abortSink(x)
                if (x.peerKnows) notifyPeer(x, outcome.notify, outcome.reason)
                if (keptPart) {
                    log("${x.id} paused after ${x.offset + x.moved.get()} bytes, $ms ms")
                    synchronized(lock) { kept[x.id] = Kept(x.status.name, x.status.size, clock()) }
                    finish(x, TransferState.PAUSED, outcome.reason)
                    return@withContext
                }
                log("${x.id} ${stateFor(outcome.reason)} ${outcome.reason} after ${x.moved.get()} bytes, $ms ms")
                finish(x, stateFor(outcome.reason), outcome.reason)
            }
        }
    }

    private suspend fun run(x: Xfer, body: suspend () -> Outcome) {
        x.started = true
        var outcome: Outcome = Outcome.Fail(TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.NONE)
        try {
            outcome = x.abort.get()?.let { Outcome.Fail(it.reason, it.notify) } ?: body()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            outcome = fail(
                x,
                if (e is LocalFault) TransferError.TRANSFER_ERROR_IO else TransferError.TRANSFER_ERROR_INTERRUPTED,
                Notify.FAILED,
            )
        } finally {
            conclude(x, outcome)
        }
    }

    // ---- bulk helpers ------------------------------------------------------------------------

    /** Fails the transfer TIMED_OUT when no bytes move for [TransferTiming.stallTimeoutMs]. */
    private fun watchdog(x: Xfer) = scope.launch {
        val tick = maxOf(timing.stallTimeoutMs / 4, 1)
        var last = x.moved.get()
        var idle = 0L
        while (true) {
            delay(tick)
            val now = x.moved.get()
            if (now != last) {
                last = now
                idle = 0
            } else {
                idle += tick
                if (idle >= timing.stallTimeoutMs) {
                    interrupt(x, TransferError.TRANSFER_ERROR_TIMED_OUT, Notify.FAILED)
                    return@launch
                }
            }
        }
    }

    /** The stream, or the failure to report. The dial is cut short by an interrupt or the stall timeout. */
    private suspend fun openBulk(x: Xfer, hello: BulkHello): Pair<BulkStream?, Outcome.Fail?> {
        val dial = scope.async {
            val s = bulk.open(hello)
            x.pendingDial.set(s)
            if (x.lateDial) closePendingDial(x) // we gave up while it was dialling
            s
        }
        val won = try {
            withTimeoutOrNull(timing.stallTimeoutMs) {
                select<Boolean> {
                    dial.onAwait { true }
                    x.interrupted.onAwait { false }
                }
            }
        } catch (e: CancellationException) {
            giveUp(x, dial)
            throw e
        } catch (e: Exception) {
            return null to fail(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.FAILED)
        }
        if (won != true) {
            giveUp(x, dial)
            return null to fail(x, TransferError.TRANSFER_ERROR_TIMED_OUT, Notify.FAILED)
        }
        val s = x.pendingDial.getAndSet(null)!!
        x.stream = s
        if (x.abort.get() != null) {
            runCatching { s.close() }
            return null to fail(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.NONE)
        }
        return s to null
    }

    private fun giveUp(x: Xfer, dial: Deferred<BulkStream>) {
        x.lateDial = true
        dial.cancel()
        closePendingDial(x) // whichever of this and the dial body runs second sees the stream
    }

    private fun closePendingDial(x: Xfer) {
        val late = x.pendingDial.getAndSet(null) ?: return
        scope.launch(io) { runCatching { late.close() } }
    }

    private fun tick(x: Xfer, done: Long, progress: ((Long) -> Unit)?) {
        val now = clock()
        if (now - x.lastTick >= timing.progressIntervalMs) {
            x.lastTick = now
            update(x) { it.copy(done = done) }
            progress?.invoke(done)
        }
    }

    private fun checkAbort(x: Xfer) {
        if (x.abort.get() != null) throw IOException("aborted")
    }

    // ---- phone sends -------------------------------------------------------------------------

    private suspend fun runSend(x: Xfer, f: OutgoingFile, kind: TransferKind) = run(x) {
        x.resumable = kind == TransferKind.TRANSFER_KIND_FILE && x.requestId == 0L && f.canResume && resumes()
        val offer = TransferOffer.newBuilder()
            .setTransferId(x.id).setName(f.name).setSize(f.size).setMime(f.mime)
            .setKind(kind).setRequestId(x.requestId).setModifiedMs(f.modifiedMs)
            .setResumable(x.resumable)
            .build()
        x.peerKnows = true
        if (!send(MessageType.FILES_OFFER, offer)) return@run fail(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.NONE)
        update(x) { it.copy(state = TransferState.WAITING) }

        val token = when (val r = withTimeoutOrNull(timing.acceptTimeoutMs) { x.reply.await() }) {
            null -> return@run fail(x, TransferError.TRANSFER_ERROR_TIMED_OUT, Notify.CANCEL)
            is Reply.Rejected -> return@run Outcome.Fail(r.reason, Notify.NONE)
            is Reply.Accepted -> {
                // The Mac kept this many bytes of an earlier try.
                x.offset = if (x.resumable) r.offset.coerceIn(0, f.size) else 0
                r.token
            }
            else -> return@run fail(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.NONE)
        }
        update(x) { it.copy(state = TransferState.ACTIVE) }

        val hello = BulkHello.newBuilder().setToken(token).setRole(BulkRole.BULK_ROLE_PHONE_SENDS).build()
        val (stream, dialFail) = openBulk(x, hello)
        if (stream == null) return@run dialFail!!
        checkAbortOutcome(x)?.let { return@run it }

        val dog = watchdog(x)
        val sha = try {
            withContext(io) { copyOut(x, f, stream) }
        } catch (e: IOException) {
            return@run fail(
                x,
                if (e is LocalFault) TransferError.TRANSFER_ERROR_IO else TransferError.TRANSFER_ERROR_INTERRUPTED,
                Notify.FAILED,
            )
        } finally {
            dog.cancel()
        }

        val complete = TransferComplete.newBuilder().setTransferId(x.id).setSha256(ByteString.copyFrom(sha)).build()
        if (!send(MessageType.FILES_COMPLETE, complete)) return@run fail(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.NONE)
        when (withTimeoutOrNull(timing.stallTimeoutMs) { x.received.await() }) {
            Reply.Received -> Outcome.Done(null)
            null -> fail(x, TransferError.TRANSFER_ERROR_TIMED_OUT, Notify.FAILED)
            else -> fail(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.NONE)
        }
    }

    private fun checkAbortOutcome(x: Xfer): Outcome.Fail? =
        x.abort.get()?.let { Outcome.Fail(it.reason, it.notify) }

    /**
     * Copies the announced size from [Xfer.offset] on, hashing the whole file (the bytes before
     * the offset are read and hashed, not sent). Blocking: run on [io].
     */
    private fun copyOut(x: Xfer, f: OutgoingFile, stream: BulkStream): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(BULK_BUFFER_BYTES)
        val src = try { f.open() } catch (e: Exception) { throw LocalFault(e) }
        src.use {
            var done = 0L
            x.lastTick = clock()
            while (done < f.size) {
                checkAbort(x)
                val want = minOf(buf.size.toLong(), (if (done < x.offset) x.offset else f.size) - done).toInt()
                val n = try { src.read(buf, 0, want) } catch (e: IOException) { throw LocalFault(e) }
                if (n < 0) throw LocalFault(null) // the file shrank
                if (done < x.offset) {
                    md.update(buf, 0, n)
                    done += n
                    continue
                }
                stream.output.write(buf, 0, n)
                md.update(buf, 0, n)
                done += n
                x.moved.addAndGet(n.toLong())
                tick(x, done, null)
            }
            val extra = try { src.read() } catch (e: IOException) { throw LocalFault(e) }
            if (extra != -1) throw LocalFault(null) // the file grew
            stream.output.flush()
        }
        return md.digest()
    }

    // ---- phone receives ----------------------------------------------------------------------

    private fun onOffer(offer: TransferOffer) {
        if (offer.transferId.isEmpty()) return
        val name = FileNames.sanitize(offer.name)
        val x = Xfer(
            offer.transferId, Direction.RECEIVE,
            TransferStatus(
                offer.transferId, Direction.RECEIVE, name, offer.size, 0, offer.kind, TransferState.QUEUED,
                browseTarget = offer.hasTarget(),
            ),
            offer.requestId,
        )
        x.resumable = offer.resumable && resumes() && offer.kind == TransferKind.TRANSFER_KIND_FILE &&
            offer.requestId == 0L && !offer.hasTarget()
        expire()
        synchronized(lock) {
            if (live.containsKey(x.id)) return
            live[x.id] = x
            // A paused receive offered again: this is its row now.
            finished.removeAll { it.id == x.id }
            publish()
        }
        val clean = offer.toBuilder().setName(name).build()
        receiveJobs.trySend(QueuedWork(x) { runReceive(x, clean) })
    }

    private suspend fun runReceive(x: Xfer, offer: TransferOffer) = run(x) {
        val size = offer.size
        fun reject(reason: TransferError): Outcome = Outcome.Fail(reason, Notify.NONE)
        suspend fun sendReject(reason: TransferError) {
            send(MessageType.FILES_REJECT, TransferReject.newBuilder().setTransferId(x.id).setReason(reason).build())
        }

        // Bytes kept from an earlier try of this transfer: go on from there when the offer still matches.
        val k = synchronized(lock) { kept.remove(x.id) }
        val resumed = if (k != null && x.resumable && k.size == size && k.name == offer.name) {
            try {
                withContext(io) {
                    sinks.resume(offer)?.let { r ->
                        if (r.offset in 1 until size) r else null.also { runCatching { r.file.abort() } }
                    }
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                null
            }
        } else {
            null
        }
        if (k != null && resumed == null) withContext(io) { runCatching { sinks.discard(x.id) } }
        x.offset = resumed?.offset ?: 0

        val free = try {
            withContext(io) { freeBytes(offer) }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            sendReject(TransferError.TRANSFER_ERROR_IO)
            return@run reject(TransferError.TRANSFER_ERROR_IO)
        }
        if (size < 0 || (free != null && size - x.offset > free - timing.freeMarginBytes)) {
            resumed?.let { withContext(io) { runCatching { it.file.abort() } } }
            sendReject(TransferError.TRANSFER_ERROR_NO_SPACE)
            return@run reject(TransferError.TRANSFER_ERROR_NO_SPACE)
        }
        val opened = try {
            resumed?.let { SinkResult.Ready(it.file) } ?: withContext(io) { sinks.open(offer) }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            sendReject(TransferError.TRANSFER_ERROR_IO)
            return@run reject(TransferError.TRANSFER_ERROR_IO)
        }
        val sink = when (val r = opened) {
            is SinkResult.Refused -> {
                sendReject(r.reason)
                return@run reject(r.reason)
            }
            is SinkResult.Ready -> r.file
        }
        x.sink = sink
        checkAbortOutcome(x)?.let { return@run it }

        val accept = TransferAccept.newBuilder().setTransferId(x.id).setOffset(x.offset).build()
        if (!send(MessageType.FILES_ACCEPT, accept)) return@run fail(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.NONE)
        update(x) { it.copy(state = TransferState.ACTIVE) }

        val hello = BulkHello.newBuilder().setToken(offer.token).setRole(BulkRole.BULK_ROLE_PHONE_RECEIVES).build()
        val (stream, dialFail) = openBulk(x, hello)
        if (stream == null) return@run dialFail!!
        checkAbortOutcome(x)?.let { return@run it }

        val progress = Channel<Long>(Channel.UNLIMITED)
        val reporter = scope.launch {
            for (n in progress) {
                send(MessageType.FILES_PROGRESS, TransferProgress.newBuilder().setTransferId(x.id).setBytesDone(n).build())
            }
        }
        val dog = watchdog(x)
        var copied = false
        val sha = try {
            withContext(io) { copyIn(x, stream, sink.output, size, resumed?.existing) { progress.trySend(it) } }.also { copied = true }
        } catch (e: EarlyEnd) {
            return@run fail(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.FAILED)
        } catch (e: IOException) {
            return@run fail(
                x,
                if (e is LocalFault) TransferError.TRANSFER_ERROR_IO else TransferError.TRANSFER_ERROR_INTERRUPTED,
                Notify.FAILED,
            )
        } finally {
            dog.cancel()
            progress.close()
            if (!copied) reporter.cancel() // nothing may follow files.failed
        }
        reporter.join()
        if (hasExtraBytes(stream)) return@run fail(x, TransferError.TRANSFER_ERROR_HASH_MISMATCH, Notify.FAILED)

        // The bytes are in; the sender's hash may arrive before or after them.
        val theirs = withTimeoutOrNull(timing.stallTimeoutMs) { x.complete.await() }
            ?: return@run fail(x, TransferError.TRANSFER_ERROR_TIMED_OUT, Notify.FAILED)
        if (hasExtraBytes(stream) || !MessageDigest.isEqual(sha, theirs)) {
            return@run fail(x, TransferError.TRANSFER_ERROR_HASH_MISMATCH, Notify.FAILED)
        }
        if (!x.sinkClaimed.compareAndSet(false, true)) return@run fail(x, TransferError.TRANSFER_ERROR_INTERRUPTED, Notify.NONE)
        val savedAs = try {
            withContext(io) { sink.commit() }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            // commit() claimed the sink, so conclude() will not abort it: remove the partial here.
            withContext(NonCancellable + io) { runCatching { sink.abort() } }
            return@run fail(x, TransferError.TRANSFER_ERROR_IO, Notify.FAILED)
        }
        send(MessageType.FILES_RECEIVED, TransferReceived.newBuilder().setTransferId(x.id).build())
        Outcome.Done(savedAs)
    }

    /**
     * Best effort: on TLS, `available()` only sees decrypted bytes already buffered, so trailing
     * bytes still in flight are missed. The SHA-256 comparison is the real integrity check.
     */
    private fun hasExtraBytes(stream: BulkStream): Boolean =
        try { stream.input.available() > 0 } catch (e: IOException) { false }

    /**
     * Reads the bytes from [Xfer.offset] to [size] into [out], hashing the whole file: the first
     * [Xfer.offset] bytes come from [existing] (the kept part). Blocking: run on [io].
     */
    private fun copyIn(
        x: Xfer,
        stream: BulkStream,
        out: OutputStream,
        size: Long,
        existing: (() -> InputStream)?,
        progress: (Long) -> Unit,
    ): ByteArray {
        val input: InputStream = stream.input
        val md = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(BULK_BUFFER_BYTES)
        if (x.offset > 0) {
            val kept = try { existing!!() } catch (e: Exception) { throw LocalFault(e) }
            kept.use {
                var left = x.offset
                while (left > 0) {
                    val n = try { it.read(buf, 0, minOf(buf.size.toLong(), left).toInt()) } catch (e: IOException) { throw LocalFault(e) }
                    if (n < 0) throw LocalFault(null)
                    md.update(buf, 0, n)
                    left -= n
                }
            }
        }
        var done = x.offset
        x.lastTick = clock()
        while (done < size) {
            checkAbort(x)
            val want = minOf(buf.size.toLong(), size - done).toInt()
            val n = input.read(buf, 0, want)
            if (n < 0) throw EarlyEnd()
            try { out.write(buf, 0, n) } catch (e: IOException) { throw LocalFault(e) }
            md.update(buf, 0, n)
            done += n
            x.moved.addAndGet(n.toLong())
            tick(x, done, progress)
        }
        try { out.flush() } catch (e: IOException) { throw LocalFault(e) }
        return md.digest()
    }

    private fun TransferError.orInterrupted() =
        if (this == TransferError.TRANSFER_ERROR_UNSPECIFIED || this == TransferError.UNRECOGNIZED) {
            TransferError.TRANSFER_ERROR_INTERRUPTED
        } else {
            this
        }

    private fun log(message: String) = System.err.println("TransferEngine: $message")

    private companion object {
        const val KEEP_FINISHED = 20
    }
}
