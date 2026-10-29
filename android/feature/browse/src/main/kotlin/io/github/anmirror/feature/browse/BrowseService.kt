package io.github.anmirror.feature.browse

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.BrowseEntry
import io.github.anmirror.protocol.v1.BrowseListRequest
import io.github.anmirror.protocol.v1.BrowseListing
import io.github.anmirror.protocol.v1.BrowseOutcome
import io.github.anmirror.protocol.v1.BrowsePath
import io.github.anmirror.protocol.v1.BrowseRename
import io.github.anmirror.protocol.v1.BrowseResult
import io.github.anmirror.protocol.v1.BrowseRoot
import io.github.anmirror.protocol.v1.BrowseRoots
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.protocol.v1.TransferOffer
import io.github.anmirror.transfer.FileNames
import io.github.anmirror.transfer.OutgoingFile
import io.github.anmirror.transfer.SinkResult
import io.github.anmirror.transfer.TransferEngine
import io.github.anmirror.transfer.TransferState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.Closeable

/**
 * Phone side of `browse.*` (SPEC 19). The caller checks that browsing is open (the Mac shares
 * browse.v1, the switch is on, there is a root) before handing a request over, and [send] sends
 * only while it still is. Every answer echoes the request's `request_id`. Reads are answered by a
 * `TRANSFER_KIND_FILE` offer carrying it; [onQueued] gets each so its descriptor can be closed
 * when the transfer ends. Writes are Mac offers with a `target`, opened by [sinkFor].
 *
 * A root whose permission is gone answers `REVOKED`: [onRevoked] drops it, and the new roots are
 * pushed. Every browse transfer is remembered with its root: [onRootsChanged] cancels those whose
 * root is gone, and [cancelAll] all of them. At most [MAX_READS] reads are outstanding (each holds
 * an open descriptor); a folder (or one above it) with a write under way can't be renamed or
 * deleted (`EXISTS`), and a read-only root refuses mkdir, delete and rename (`DENIED`). Logs carry
 * request IDs, root IDs, counts and outcomes only, never paths or names.
 */
class BrowseService(
    private val roots: RootsSource,
    private val send: suspend (String, MessageLite) -> Boolean,
    private val transfers: TransferEngine,
    private val onRevoked: (RootInfo) -> Unit = {},
    private val onQueued: (String, OutgoingFile) -> Unit = { _, _ -> },
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val log: (String) -> Unit = {},
) {
    /** A browse transfer: its root, and for a write the folder it writes into. */
    private open class Tracked(val rootId: String, val write: Boolean, val dir: List<String>)

    /**
     * A transfer being opened (tree lookup and open under way). [cancelled] is set, under [lock],
     * when its root goes or browsing closes meanwhile: the open's handle is then closed at once
     * and no transfer starts.
     */
    private class Pending(rootId: String, write: Boolean, dir: List<String>) : Tracked(rootId, write, dir) {
        var cancelled: TransferError? = null
    }

    private val lock = Any()
    private val tracked = HashMap<String, Tracked>() // transfer ID → what it is; under [lock]
    private val pending = HashSet<Pending>() // under [lock]

    /** `browse.roots_request`: answered by `browse.roots`. */
    suspend fun onRootsRequest() = pushRoots()

    /** Sends `browse.roots`: on connect, on request, and whenever the roots change. */
    suspend fun pushRoots() {
        val list = withContext(io) { roots.trees() }.map { it.root }
        val message = BrowseRoots.newBuilder().addAllRoots(list.map { it.toProto() }).build()
        send(MessageType.BROWSE_ROOTS, message)
        log("browse: pushed ${list.size} roots")
    }

    /** `browse.list`: directories first, then by name ignoring case; `limit` clamped to 1..500. */
    suspend fun onList(r: BrowseListRequest) {
        val ran = run(r.rootId, r.path) { it.list(r.path) }
        val result = ran.result
        val listing = BrowseListing.newBuilder().setRequestId(r.requestId)
        when (result) {
            is TreeResult.Err -> listing.setOutcome(result.outcome)
            is TreeResult.Ok -> {
                val sorted = result.value.sortedWith(ORDER)
                // uint32 on the wire: a value past Int.MAX_VALUE reads as negative here.
                val limit = if (r.limit < 0) MAX_PAGE else r.limit.coerceIn(1, MAX_PAGE)
                val offset = if (r.offset < 0) sorted.size else minOf(r.offset, sorted.size)
                val page = sorted.subList(offset, minOf(sorted.size, offset + limit))
                val next = offset + page.size
                listing.setOutcome(BrowseOutcome.BROWSE_OUTCOME_OK)
                    .addAllEntries(page.map { it.toProto() })
                    .setNextOffset(next)
                    .setMore(next < sorted.size)
            }
        }
        send(MessageType.BROWSE_LISTING, listing.build())
        log("browse: list ${r.requestId} ${listing.outcome} ${listing.entriesCount}")
        settle(ran)
    }

    suspend fun onStat(p: BrowsePath) = answer("stat", p.requestId, run(p.rootId, p.path) { it.stat(p.path) })

    suspend fun onMkdir(p: BrowsePath) =
        answer("mkdir", p.requestId, run(p.rootId, p.path, change = true) { it.mkdir(p.path) })

    /** `browse.delete`: `EXISTS` while a write goes into this folder or one below it. */
    suspend fun onDelete(p: BrowsePath) {
        val ran = if (writing(p.rootId, p.path)) Ran(null, exists) else run(p.rootId, p.path, change = true) { it.delete(p.path) }
        answer("delete", p.requestId, ran)
    }

    /** `browse.rename`: a `new_name` that is not its own sanitized form (SPEC 16) is `BAD_PATH`. */
    suspend fun onRename(r: BrowseRename) {
        val ran = when {
            r.newName.isEmpty() || r.newName != FileNames.sanitize(r.newName) -> Ran(null, TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH))
            writing(r.rootId, r.path) -> Ran(null, exists)
            else -> run(r.rootId, r.path, change = true) { it.rename(r.path, r.newName) }
        }
        answer("rename", r.requestId, ran)
    }

    /**
     * `browse.read`: the file goes as a `TRANSFER_KIND_FILE` offer carrying the request's ID, or
     * `browse.result` says why not. A read without a request ID can't be answered as one (it would
     * look like a file the user shared) and is `BAD_PATH`. With [MAX_READS] reads outstanding, a
     * new one is `IO` and nothing is opened for it.
     */
    suspend fun onRead(p: BrowsePath) {
        if (p.requestId == 0L) return answer("read", p.requestId, Ran(null, TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH)))
        // Pending before the lookup and the open, so a root that goes meanwhile cancels it.
        val mine = Pending(p.rootId, write = false, dir = emptyList())
        val room = synchronized(lock) {
            prune()
            val open = tracked.values.count { !it.write } + pending.count { !it.write }
            (open < MAX_READS).also { if (it) pending += mine }
        }
        if (!room) {
            log("browse: read ${p.requestId} refused, $MAX_READS outstanding")
            return answer("read", p.requestId, Ran(null, TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_IO)))
        }
        val ran = try {
            run(p.rootId, p.path) { it.openRead(p.path) }
        } catch (e: Throwable) {
            synchronized(lock) { pending -= mine }
            throw e
        }
        when (val result = ran.result) {
            is TreeResult.Err -> {
                synchronized(lock) { pending -= mine }
                answer("read", p.requestId, ran)
            }
            is TreeResult.Ok -> {
                val file = result.value
                // The engine only queues here: starting the transfer and tracking it happen together.
                val id = synchronized(lock) {
                    pending -= mine
                    if (mine.cancelled != null) {
                        null
                    } else {
                        transfers.send(listOf(file), TransferKind.TRANSFER_KIND_FILE, p.requestId).single()
                            .also { tracked[it] = Tracked(p.rootId, write = false, dir = emptyList()) }
                    }
                }
                if (id == null) {
                    (file as? Closeable)?.close()
                    log("browse: read ${p.requestId} cancelled while opening")
                    return answer("read", p.requestId, Ran(null, TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND)))
                }
                onQueued(id, file)
                log("browse: read ${p.requestId} queued as $id")
            }
        }
    }

    /**
     * The roots changed: browse transfers whose root is gone (removed, revoked, access withdrawn)
     * stop, including those still being opened.
     */
    fun onRootsChanged() {
        val live = roots.trees().mapTo(HashSet()) { it.root.id }
        cancelWhere(TransferError.TRANSFER_ERROR_BAD_TARGET) { it.rootId !in live }
    }

    /**
     * Browsing closed: every browse transfer stops (the Mac is told), those being opened, and
     * browse writes still waiting their turn (they would go ahead if browsing reopened first).
     */
    fun cancelAll() {
        cancelWhere(TransferError.TRANSFER_ERROR_DISABLED) { true }
        val waiting = transfers.transfers.value.filter { it.browseTarget && it.state == TransferState.QUEUED }
        waiting.forEach { transfers.cancel(it.id) }
        if (waiting.isNotEmpty()) log("browse: cancelled ${waiting.size} queued writes")
    }

    private fun cancelWhere(reason: TransferError, gone: (Tracked) -> Boolean) {
        val ids = synchronized(lock) {
            prune()
            pending.filter(gone).forEach { it.cancelled = reason }
            val ids = tracked.filterValues(gone).keys.toList()
            ids.forEach(tracked::remove)
            ids
        }
        ids.forEach(transfers::cancel)
        if (ids.isNotEmpty()) log("browse: cancelled ${ids.size} transfers")
    }

    /** Forgets transfers that ended. Under [lock]. */
    private fun prune() {
        val ongoing = transfers.transfers.value.filter { it.state in ONGOING }.mapTo(HashSet()) { it.id }
        tracked.keys.retainAll(ongoing)
    }

    /** A write under way goes into [path] of [rootId], or a folder below it. */
    private fun writing(rootId: String, path: String): Boolean {
        val segments = BrowsePaths.segments(path)?.map(FileNames::key) ?: return false
        if (segments.isEmpty()) return false
        return synchronized(lock) {
            prune()
            (tracked.values + pending).any { t ->
                t.write && t.rootId == rootId && t.dir.size >= segments.size &&
                    t.dir.subList(0, segments.size).map(FileNames::key) == segments
            }
        }
    }

    /**
     * Opens the destination of a Mac offer with a `target` (a browse write). An unknown root, a
     * bad folder path or a folder of that name is `BAD_TARGET`; a read-only or revoked root is
     * `DENIED` (a revoked one is dropped and the roots pushed). Blocking: the engine calls it on
     * its I/O dispatcher.
     */
    fun sinkFor(offer: TransferOffer): SinkResult {
        if (!offer.hasTarget()) return SinkResult.Refused(TransferError.TRANSFER_ERROR_BAD_TARGET)
        val target = offer.target
        val segments = BrowsePaths.segments(target.dirPath)
        if (segments == null || segments.any { PART_NAME.matches(it) }) return SinkResult.Refused(TransferError.TRANSFER_ERROR_BAD_TARGET)
        // Pending before the lookup and the open, so a root that goes meanwhile refuses it.
        val mine = Pending(target.rootId, write = true, dir = segments)
        synchronized(lock) { pending += mine }
        try {
            return openWrite(offer, mine)
        } finally {
            synchronized(lock) { pending -= mine }
        }
    }

    private fun openWrite(offer: TransferOffer, mine: Pending): SinkResult {
        val target = offer.target
        val tree = tree(target.rootId) ?: return SinkResult.Refused(TransferError.TRANSFER_ERROR_BAD_TARGET)
        if (!tree.root.writable) return SinkResult.Refused(TransferError.TRANSFER_ERROR_DENIED)
        return when (val r = tree.openWrite(target.dirPath, offer.name, target.overwrite)) {
            is TreeResult.Ok -> {
                val file = r.value
                // Off the primary volume the engine can't know the room; the part's own volume can.
                if (!fitsFreeSpace(offer.size, (file as? SpaceAware)?.freeBytes())) {
                    runCatching { file.abort() }
                    log("browse: write ${offer.transferId} refused NO_SPACE")
                    return SinkResult.Refused(TransferError.TRANSFER_ERROR_NO_SPACE)
                }
                val cancelled = synchronized(lock) {
                    mine.cancelled.also { if (it == null) tracked[offer.transferId] = Tracked(tree.root.id, write = true, dir = mine.dir) }
                }
                if (cancelled != null) {
                    runCatching { file.abort() }
                    log("browse: write ${offer.transferId} cancelled while opening")
                    return SinkResult.Refused(cancelled)
                }
                SinkResult.Ready(file)
            }
            is TreeResult.Err -> {
                if (r.outcome == BrowseOutcome.BROWSE_OUTCOME_REVOKED) {
                    revoked(tree)
                    scope.launch {
                        try {
                            pushRoots()
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            log("browse: push failed (${e.javaClass.simpleName})") // the class only: a message could carry a URI
                        }
                    }
                }
                log("browse: write ${offer.transferId} refused ${r.outcome}")
                SinkResult.Refused(r.outcome.toTransferError())
            }
        }
    }

    /** Free bytes where [offer] would be written; null when unknown (or not a browse write). */
    fun freeBytes(offer: TransferOffer): Long? {
        if (!offer.hasTarget()) return null
        return tree(offer.target.rootId)?.freeBytes(offer.target.dirPath)
    }

    // ---- helpers ---------------------------------------------------------------------------

    private fun tree(rootId: String): FileTree? = roots.trees().firstOrNull { it.root.id == rootId }

    /** What [run] did: the tree it ran on (null when there was none) and the result. */
    private class Ran<out T>(val tree: FileTree?, val result: TreeResult<T>)

    /**
     * Runs [op] on the root's tree off the main thread. A bad path, or one through an in-progress
     * `.<uuid>.part` (never listed), does not reach the tree; an unknown root is `NOT_FOUND`.
     */
    private suspend fun <T> run(rootId: String, path: String, change: Boolean = false, op: (FileTree) -> TreeResult<T>): Ran<T> {
        val segments = BrowsePaths.segments(path) ?: return Ran(null, TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH))
        if (segments.any { PART_NAME.matches(it) }) return Ran(null, TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND))
        return withContext(io) {
            val tree = tree(rootId) ?: return@withContext Ran(null, TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND))
            if (change && !tree.root.writable) return@withContext Ran(tree, TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_DENIED))
            Ran(tree, op(tree))
        }
    }

    /**
     * After the answer went out: a tree that answered `REVOKED` is dropped and the roots pushed
     * (in this order, as dropping the last root closes browsing, and with it [send]).
     */
    private suspend fun settle(ran: Ran<*>) {
        val tree = ran.tree ?: return
        val result = ran.result
        if (result is TreeResult.Err && result.outcome == BrowseOutcome.BROWSE_OUTCOME_REVOKED) {
            revoked(tree)
            pushRoots()
        }
    }

    private fun revoked(tree: FileTree) {
        log("browse: root ${tree.root.id} revoked")
        onRevoked(tree.root)
    }

    private suspend fun answer(what: String, requestId: Long, ran: Ran<*>) {
        val message = BrowseResult.newBuilder().setRequestId(requestId)
        when (val result = ran.result) {
            is TreeResult.Err -> message.setOutcome(result.outcome)
            is TreeResult.Ok -> {
                message.setOutcome(BrowseOutcome.BROWSE_OUTCOME_OK)
                (result.value as? EntryInfo)?.let { message.setEntry(it.toProto()) }
            }
        }
        send(MessageType.BROWSE_RESULT, message.build())
        log("browse: $what $requestId ${message.outcome}")
        settle(ran)
    }

    private fun RootInfo.toProto(): BrowseRoot =
        BrowseRoot.newBuilder().setId(id).setName(name).setKind(kind).setWritable(writable).build()

    private fun EntryInfo.toProto(): BrowseEntry = BrowseEntry.newBuilder()
        .setName(name).setIsDir(isDir).setSize(size.coerceAtLeast(0)).setModifiedMs(modifiedMs).setMime(mime)
        .build()

    private fun BrowseOutcome.toTransferError(): TransferError = when (this) {
        BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND -> TransferError.TRANSFER_ERROR_NOT_FOUND
        BrowseOutcome.BROWSE_OUTCOME_DENIED, BrowseOutcome.BROWSE_OUTCOME_REVOKED -> TransferError.TRANSFER_ERROR_DENIED
        BrowseOutcome.BROWSE_OUTCOME_IO -> TransferError.TRANSFER_ERROR_IO
        else -> TransferError.TRANSFER_ERROR_BAD_TARGET
    }

    companion object {
        /** `browse.listing` page limit (Global Constraints). */
        const val MAX_PAGE = 500

        /** Outstanding browse reads (each holds an open descriptor until its transfer ends). */
        const val MAX_READS = 64

        private val ONGOING = setOf(TransferState.QUEUED, TransferState.WAITING, TransferState.ACTIVE)
        private val exists = TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_EXISTS)

        private val ORDER: Comparator<EntryInfo> = compareBy<EntryInfo> { !it.isDir }
            .thenBy(String.CASE_INSENSITIVE_ORDER) { it.name }
            .thenBy { it.name }
    }
}
