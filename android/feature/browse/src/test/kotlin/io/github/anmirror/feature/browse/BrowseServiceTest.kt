package io.github.anmirror.feature.browse

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.envelope
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.BrowseListRequest
import io.github.anmirror.protocol.v1.BrowseListing
import io.github.anmirror.protocol.v1.BrowseOutcome
import io.github.anmirror.protocol.v1.BrowsePath
import io.github.anmirror.protocol.v1.BrowseRename
import io.github.anmirror.protocol.v1.BrowseResult
import io.github.anmirror.protocol.v1.BrowseRoots
import io.github.anmirror.protocol.v1.BrowseTarget
import io.github.anmirror.protocol.v1.RootKind
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.protocol.v1.TransferOffer
import io.github.anmirror.transfer.BulkOpener
import io.github.anmirror.transfer.IncomingFile
import io.github.anmirror.transfer.OutgoingFile
import io.github.anmirror.transfer.SinkResult
import io.github.anmirror.transfer.TransferEngine
import io.github.anmirror.transfer.TransferState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertSame
import kotlin.test.assertTrue

private class MemFile(override val name: String, data: ByteArray) : OutgoingFile {
    private val bytes = data
    override val size = data.size.toLong()
    override val mime = "text/plain"
    override val modifiedMs = 1_700_000_000_000L
    override fun open(): InputStream = ByteArrayInputStream(bytes)
}

private open class MemSink : IncomingFile {
    override val output: OutputStream = ByteArrayOutputStream()
    @Volatile var aborted = false
    override fun commit() = "x"
    override fun abort() { aborted = true }
}

/** A sink whose volume can't say how much room it has. */
private class BlindSink : MemSink(), SpaceAware {
    override fun freeBytes(): Long = throw IllegalStateException("statvfs")
}

/** A sink on a nearly full volume. */
private class TightSink(private val free: Long) : MemSink(), SpaceAware {
    override fun freeBytes(): Long = free
}

/** A file whose descriptor the test can see closed. */
private class ClosableFile(override val name: String) : OutgoingFile, java.io.Closeable {
    @Volatile var closed = false
    override val size = 1L
    override val mime = "text/plain"
    override val modifiedMs = 1L
    override fun open(): InputStream = ByteArrayInputStream(ByteArray(1))
    override fun close() { closed = true }
}

/** [inner], with opens that wait for [gate] (after counting down [entered]). */
private class GatedTree(val inner: FakeTree) : FileTree by inner {
    val entered = java.util.concurrent.CountDownLatch(1)
    val gate = java.util.concurrent.CountDownLatch(1)
    override fun openRead(path: String): TreeResult<OutgoingFile> {
        entered.countDown()
        gate.await()
        return inner.openRead(path)
    }
    override fun openWrite(dirPath: String, name: String, overwrite: Boolean): TreeResult<IncomingFile> {
        entered.countDown()
        gate.await()
        return inner.openWrite(dirPath, name, overwrite)
    }
}

private fun file(name: String, size: Long = 1) = EntryInfo(name, false, size, 1, "text/plain")
private fun dir(name: String) = EntryInfo(name, true, 0, 1, "")

/** A tree whose answers the test sets; it records every call it gets. */
private class FakeTree(
    override val root: RootInfo,
    var entries: List<EntryInfo> = emptyList(),
    var failure: BrowseOutcome? = null,
    val readable: Map<String, OutgoingFile> = emptyMap(),
    val sink: MemSink = MemSink(),
) : FileTree {
    val calls = CopyOnWriteArrayList<String>()
    val writes = CopyOnWriteArrayList<Triple<String, String, Boolean>>()

    private fun <T> answer(call: String, value: () -> T): TreeResult<T> {
        calls += call
        return failure?.let { TreeResult.Err(it) } ?: TreeResult.Ok(value())
    }

    override fun list(path: String) = answer("list $path") { entries }
    override fun stat(path: String) = answer("stat $path") { file(path.substringAfterLast('/')) }
    override fun mkdir(path: String) = answer("mkdir $path") { dir(path.substringAfterLast('/')) }
    override fun delete(path: String) = answer("delete $path") { }
    override fun rename(path: String, newName: String) = answer("rename $path $newName") { file(newName) }
    override fun openRead(path: String): TreeResult<OutgoingFile> {
        calls += "read $path"
        failure?.let { return TreeResult.Err(it) }
        return readable[path]?.let { TreeResult.Ok(it) } ?: TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND)
    }
    override fun openWrite(dirPath: String, name: String, overwrite: Boolean): TreeResult<IncomingFile> {
        writes += Triple(dirPath, name, overwrite)
        return answer("write $dirPath") { sink }
    }
}

class BrowseServiceTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val sent = CopyOnWriteArrayList<Pair<String, MessageLite>>()
    private val queued = CopyOnWriteArrayList<Pair<String, OutgoingFile>>()
    private val revoked = CopyOnWriteArrayList<RootInfo>()
    private val ids = AtomicInteger()

    @Volatile private var browse: BrowseService? = null

    /** Mac offers with a target go to the service, as in the app; a bulk dial never completes. */
    private val engine = TransferEngine(
        scope = scope,
        send = { type, payload -> sent += type to payload; true },
        bulk = BulkOpener { awaitCancellation() },
        sinks = { offer -> browse?.sinkFor(offer) ?: SinkResult.Refused(TransferError.TRANSFER_ERROR_DISABLED) },
        freeBytes = { null },
        newId = { "t${ids.incrementAndGet()}" },
    )

    private val picked = RootInfo("0123456789abcdef", "Documents", RootKind.ROOT_KIND_PICKED_FOLDER, true)
    private val other = RootInfo("fedcba9876543210", "Music", RootKind.ROOT_KIND_PICKED_FOLDER, false)
    private val trees = CopyOnWriteArrayList<FileTree>()

    /** Like the app: nothing is sent once there is no root left (browsing closed). */
    private fun service(vararg tree: FileTree): BrowseService {
        trees.addAll(tree)
        return BrowseService(
            roots = { trees.toList() },
            send = { type, payload -> trees.isNotEmpty() && sent.add(type to payload) },
            transfers = engine,
            onRevoked = { root ->
                revoked += root
                trees.removeIf { it.root.id == root.id }
            },
            onQueued = { id, f -> queued += id to f },
            scope = scope,
            io = Dispatchers.IO,
        ).also { browse = it }
    }

    private fun state(id: String) = engine.transfers.value.firstOrNull { it.id == id }?.state

    /** A Mac write into [root]/[dir], delivered to the engine; it waits in the bulk dial once its sink is open. */
    private fun macWrite(id: String, root: String, dir: String) = runBlocking {
        val offer = writeOffer(root, dir).toBuilder().setTransferId(id).build()
        engine.onMessage(envelope(Channel.CHANNEL_FILES, 1, MessageType.FILES_OFFER, offer))
        awaitUntil("$id active") { state(id) == TransferState.ACTIVE }
    }

    @After
    fun tearDown() = scope.cancel()

    /** Polls [condition] for up to [ms]: generous, as the bound only matters when the test fails. */
    private fun awaitUntil(what: String, ms: Long = 30_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + ms
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) throw AssertionError("timed out waiting for $what")
            Thread.sleep(2)
        }
    }

    private fun list(id: Long, root: String, path: String = "", offset: Int = 0, limit: Int = 50) =
        BrowseListRequest.newBuilder().setRequestId(id).setRootId(root).setPath(path).setOffset(offset).setLimit(limit).build()

    private fun path(id: Long, root: String, p: String) =
        BrowsePath.newBuilder().setRequestId(id).setRootId(root).setPath(p).build()

    private fun rename(id: Long, root: String, p: String, newName: String) =
        BrowseRename.newBuilder().setRequestId(id).setRootId(root).setPath(p).setNewName(newName).build()

    private inline fun <reified T : MessageLite> last(type: String): T = sent.last { it.first == type }.second as T

    private fun writeOffer(root: String, dirPath: String, overwrite: Boolean = false) = TransferOffer.newBuilder()
        .setTransferId("m1").setName("up.txt").setSize(3).setKind(TransferKind.TRANSFER_KIND_FILE)
        .setTarget(BrowseTarget.newBuilder().setRootId(root).setDirPath(dirPath).setOverwrite(overwrite))
        .build()

    @Test fun rootsArePushedOnRequest() = runBlocking {
        val browse = service(FakeTree(picked), FakeTree(other))
        browse.onRootsRequest()
        val roots = last<BrowseRoots>(MessageType.BROWSE_ROOTS).rootsList
        assertEquals(listOf(picked.id, other.id), roots.map { it.id })
        assertEquals("Documents", roots[0].name)
        assertEquals(RootKind.ROOT_KIND_PICKED_FOLDER, roots[0].kind)
        assertTrue(roots[0].writable)
        assertFalse(roots[1].writable)
    }

    @Test fun listPagesDirsFirstByName() = runBlocking {
        val tree = FakeTree(picked, entries = listOf(file("b.txt"), dir("zeta"), file("Banana.txt", 7), dir("Alpha"), file("apple.txt")))
        val browse = service(tree)

        browse.onList(list(1, picked.id, "docs", offset = 0, limit = 3))
        val first = last<BrowseListing>(MessageType.BROWSE_LISTING)
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_OK, first.outcome)
        assertEquals(listOf("Alpha", "zeta", "apple.txt"), first.entriesList.map { it.name })
        assertTrue(first.entriesList[0].isDir)
        assertEquals(3, first.nextOffset)
        assertTrue(first.more)
        assertEquals("list docs", tree.calls.single())

        browse.onList(list(2, picked.id, "docs", offset = 3, limit = 3))
        val second = last<BrowseListing>(MessageType.BROWSE_LISTING)
        assertEquals(listOf("b.txt", "Banana.txt"), second.entriesList.map { it.name })
        assertEquals(7L, second.entriesList[1].size)
        assertEquals(5, second.nextOffset)
        assertFalse(second.more)

        // Past the end is an empty last page.
        browse.onList(list(3, picked.id, "docs", offset = 9, limit = 3))
        val past = last<BrowseListing>(MessageType.BROWSE_LISTING)
        assertEquals(0, past.entriesCount)
        assertFalse(past.more)
    }

    @Test fun listLimitIsClampedTo500() = runBlocking {
        val browse = service(FakeTree(picked, entries = (1..600).map { file("f%04d".format(it)) }))
        browse.onList(list(1, picked.id, limit = 1_000))
        last<BrowseListing>(MessageType.BROWSE_LISTING).let {
            assertEquals(500, it.entriesCount)
            assertEquals(500, it.nextOffset)
            assertTrue(it.more)
        }
        // uint32 limits past Int.MAX_VALUE read as negative: a big ask, so 500 too.
        browse.onList(list(2, picked.id, limit = -1))
        assertEquals(500, last<BrowseListing>(MessageType.BROWSE_LISTING).entriesCount)
        // 0 (unset) is at least one.
        browse.onList(list(3, picked.id, limit = 0))
        assertEquals(1, last<BrowseListing>(MessageType.BROWSE_LISTING).entriesCount)
    }

    @Test fun renameRefusesSlash() = runBlocking {
        val tree = FakeTree(picked)
        val browse = service(tree)
        for ((i, bad) in listOf("a/b", "..", "x\\y.txt", ".hidden", "", "tail ").withIndex()) {
            browse.onRename(rename(10L + i, picked.id, "a.txt", bad))
            val result = last<BrowseResult>(MessageType.BROWSE_RESULT)
            assertEquals(10L + i, result.requestId)
            assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, result.outcome, bad)
        }
        assertTrue(tree.calls.isEmpty(), "no bad name reaches the tree")
        browse.onRename(rename(20, picked.id, "a.txt", "b (1).txt"))
        last<BrowseResult>(MessageType.BROWSE_RESULT).let {
            assertEquals(BrowseOutcome.BROWSE_OUTCOME_OK, it.outcome)
            assertEquals("b (1).txt", it.entry.name)
        }
    }

    @Test fun badPathNeverReachesTree() = runBlocking {
        val tree = FakeTree(picked)
        val browse = service(tree)
        browse.onStat(path(1, picked.id, "../x"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        browse.onDelete(path(2, picked.id, "/etc"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        browse.onList(list(3, picked.id, "a//b"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, last<BrowseListing>(MessageType.BROWSE_LISTING).outcome)
        browse.onRead(path(4, picked.id, "a/\u0000"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        assertEquals(SinkResult.Refused(TransferError.TRANSFER_ERROR_BAD_TARGET), browse.sinkFor(writeOffer(picked.id, "../up")))
        assertTrue(tree.calls.isEmpty())
    }

    @Test fun readAnswersWithOfferCarryingRequestId() = runBlocking {
        val f = MemFile("notes.txt", "hello".toByteArray())
        val browse = service(FakeTree(picked, readable = mapOf("docs/notes.txt" to f)))
        browse.onRead(path(77, picked.id, "docs/notes.txt"))
        awaitUntil("offer") { sent.any { it.first == MessageType.FILES_OFFER } }
        val offer = last<TransferOffer>(MessageType.FILES_OFFER)
        assertEquals(77L, offer.requestId)
        assertEquals(TransferKind.TRANSFER_KIND_FILE, offer.kind)
        assertEquals("notes.txt", offer.name)
        assertEquals(5L, offer.size)
        val (id, queuedFile) = queued.single()
        assertEquals(offer.transferId, id)
        assertSame(f, queuedFile)
        assertTrue(sent.none { it.first == MessageType.BROWSE_RESULT }, "a read is answered by the offer alone")
    }

    @Test fun readOfMissingAnswersNotFound() = runBlocking {
        val browse = service(FakeTree(picked))
        browse.onRead(path(78, picked.id, "gone.txt"))
        val result = last<BrowseResult>(MessageType.BROWSE_RESULT)
        assertEquals(78L, result.requestId)
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, result.outcome)
        assertTrue(sent.none { it.first == MessageType.FILES_OFFER })
        assertTrue(queued.isEmpty())
    }

    @Test fun revokedTreeReportsRevokedAndDropsRoot() = runBlocking {
        val gone = FakeTree(picked, failure = BrowseOutcome.BROWSE_OUTCOME_REVOKED)
        val browse = service(gone, FakeTree(other))
        browse.onList(list(5, picked.id))
        val listing = last<BrowseListing>(MessageType.BROWSE_LISTING)
        assertEquals(5L, listing.requestId)
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_REVOKED, listing.outcome)
        assertEquals(listOf(picked), revoked)
        assertEquals(listOf(other.id), last<BrowseRoots>(MessageType.BROWSE_ROOTS).rootsList.map { it.id })
        // The root is gone now.
        browse.onStat(path(6, picked.id, ""))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
    }

    @Test fun revokedAnswerGoesOutBeforeTheLastRootIsDropped() = runBlocking {
        // The only root: once it is dropped browsing closes, so the answer must already be out.
        val browse = service(FakeTree(picked, failure = BrowseOutcome.BROWSE_OUTCOME_REVOKED))
        browse.onStat(path(9, picked.id, "a.txt"))
        val result = last<BrowseResult>(MessageType.BROWSE_RESULT)
        assertEquals(9L, result.requestId)
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_REVOKED, result.outcome)
        assertEquals(listOf(picked), revoked)
        assertTrue(trees.isEmpty())
    }

    @Test fun partFilesAreNotReachable() = runBlocking {
        val tree = FakeTree(picked)
        val browse = service(tree)
        browse.onRead(path(1, picked.id, "docs/.0f8fad5b-d9cb-469f-a165-70867728950e.part"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        browse.onDelete(path(2, picked.id, ".0f8fad5b-d9cb-469f-a165-70867728950e.part/x"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        browse.onStat(path(3, picked.id, ".0F8FAD5B-D9CB-469F-A165-70867728950E.PART"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        assertTrue(tree.calls.isEmpty())
    }

    @Test fun revokedWriteIsRefusedAndDropsRoot() {
        val browse = service(FakeTree(picked, failure = BrowseOutcome.BROWSE_OUTCOME_REVOKED), FakeTree(other))
        assertEquals(SinkResult.Refused(TransferError.TRANSFER_ERROR_DENIED), browse.sinkFor(writeOffer(picked.id, "")))
        assertEquals(listOf(picked), revoked)
        awaitUntil("roots pushed") { sent.any { it.first == MessageType.BROWSE_ROOTS } }
        assertEquals(listOf(other.id), last<BrowseRoots>(MessageType.BROWSE_ROOTS).rootsList.map { it.id })
    }

    @Test fun unknownRootIsNotFound() = runBlocking {
        val browse = service(FakeTree(picked))
        browse.onStat(path(1, "nope", ""))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        browse.onList(list(2, "nope"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, last<BrowseListing>(MessageType.BROWSE_LISTING).outcome)
        browse.onRead(path(3, "nope", "a.txt"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        assertEquals(SinkResult.Refused(TransferError.TRANSFER_ERROR_BAD_TARGET), browse.sinkFor(writeOffer("nope", "")))
    }

    @Test fun writeGoesToTargetTree() {
        val tree = FakeTree(picked)
        val readOnly = FakeTree(other)
        val browse = service(tree, readOnly)
        val ready = assertIs<SinkResult.Ready>(browse.sinkFor(writeOffer(picked.id, "docs", overwrite = true)))
        assertSame(tree.sink, ready.file)
        assertEquals(Triple("docs", "up.txt", true), tree.writes.single())
        // A root the phone can't write to refuses before anything is opened.
        assertEquals(SinkResult.Refused(TransferError.TRANSFER_ERROR_DENIED), browse.sinkFor(writeOffer(other.id, "")))
        assertTrue(readOnly.writes.isEmpty())
        // An offer without a target is not a browse write.
        assertEquals(
            SinkResult.Refused(TransferError.TRANSFER_ERROR_BAD_TARGET),
            browse.sinkFor(writeOffer(picked.id, "").toBuilder().clearTarget().build()),
        )
    }

    @Test fun answersEchoRequestId() = runBlocking {
        val tree = FakeTree(picked, entries = listOf(file("a.txt")))
        val browse = service(tree)
        browse.onList(list(101, picked.id))
        assertEquals(101L, last<BrowseListing>(MessageType.BROWSE_LISTING).requestId)
        browse.onStat(path(102, picked.id, "a.txt"))
        assertEquals(102L, last<BrowseResult>(MessageType.BROWSE_RESULT).requestId)
        browse.onMkdir(path(103, picked.id, "new"))
        last<BrowseResult>(MessageType.BROWSE_RESULT).let {
            assertEquals(103L, it.requestId)
            assertEquals(BrowseOutcome.BROWSE_OUTCOME_OK, it.outcome)
            assertEquals("new", it.entry.name)
            assertTrue(it.entry.isDir)
        }
        browse.onDelete(path(104, picked.id, "a.txt"))
        last<BrowseResult>(MessageType.BROWSE_RESULT).let {
            assertEquals(104L, it.requestId)
            assertEquals(BrowseOutcome.BROWSE_OUTCOME_OK, it.outcome)
        }
        browse.onRename(rename(105, picked.id, "a.txt", "b.txt"))
        assertEquals(105L, last<BrowseResult>(MessageType.BROWSE_RESULT).requestId)
        tree.failure = BrowseOutcome.BROWSE_OUTCOME_DENIED
        browse.onDelete(path(106, picked.id, "a.txt"))
        last<BrowseResult>(MessageType.BROWSE_RESULT).let {
            assertEquals(106L, it.requestId)
            assertEquals(BrowseOutcome.BROWSE_OUTCOME_DENIED, it.outcome)
        }
        browse.onList(list(107, picked.id))
        assertEquals(107L, last<BrowseListing>(MessageType.BROWSE_LISTING).requestId)
    }

    @Test fun removingARootCancelsItsTransfers() = runBlocking {
        val mine = FakeTree(picked, readable = mapOf("a.txt" to MemFile("a.txt", ByteArray(3))))
        val theirs = FakeTree(other, readable = mapOf("b.txt" to MemFile("b.txt", ByteArray(3))))
        val browse = service(mine, theirs)
        browse.onRead(path(1, picked.id, "a.txt"))
        browse.onRead(path(2, other.id, "b.txt"))
        val (readMine, readTheirs) = queued.map { it.first }
        macWrite("m1", picked.id, "")
        assertTrue(listOf(readMine, readTheirs, "m1").all { state(it) != TransferState.CANCELLED })

        // Removed (or revoked, or All files access withdrawn): the root is no longer listed.
        trees.remove(mine)
        browse.onRootsChanged()
        awaitUntil("cancelled") { state(readMine) == TransferState.CANCELLED && state("m1") == TransferState.CANCELLED }
        assertTrue(state(readTheirs) in setOf(TransferState.QUEUED, TransferState.WAITING), "the other root's read goes on")
    }

    @Test fun browseReadsAreCapped() = runBlocking {
        val files = (1..65).associate { "f$it.txt" to MemFile("f$it.txt", ByteArray(1)) }
        val tree = FakeTree(picked, readable = files)
        val browse = service(tree)
        for (i in 1..64) browse.onRead(path(i.toLong(), picked.id, "f$i.txt"))
        assertEquals(64, queued.size)
        browse.onRead(path(65, picked.id, "f65.txt"))
        val refused = last<BrowseResult>(MessageType.BROWSE_RESULT)
        assertEquals(65L, refused.requestId)
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_IO, refused.outcome)
        assertFalse("read f65.txt" in tree.calls, "nothing is opened for a refused read")
        assertEquals(64, queued.size)

        // Once one ends, there is room again.
        engine.cancel(queued.first().first)
        awaitUntil("ended") { state(queued.first().first) == TransferState.CANCELLED }
        browse.onRead(path(66, picked.id, "f65.txt"))
        assertEquals(65, queued.size)
    }

    @Test fun activeWriteBlocksRenameAndDeleteOfItsFolders() = runBlocking {
        val tree = FakeTree(picked)
        val browse = service(tree)
        macWrite("m1", picked.id, "docs/sub")
        for ((i, p) in listOf("docs", "docs/sub", "Docs").withIndex()) {
            browse.onDelete(path(10L + i, picked.id, p))
            assertEquals(BrowseOutcome.BROWSE_OUTCOME_EXISTS, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome, p)
            browse.onRename(rename(20L + i, picked.id, p, "x"))
            assertEquals(BrowseOutcome.BROWSE_OUTCOME_EXISTS, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome, p)
        }
        assertTrue(tree.calls.none { it.startsWith("delete") || it.startsWith("rename") })
        // A sibling, or a file inside the folder being written, is fine.
        browse.onDelete(path(30, picked.id, "other"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_OK, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        browse.onDelete(path(31, picked.id, "docs/sub/old.txt"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_OK, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        // Once the write ends, the folder can go.
        engine.cancel("m1")
        awaitUntil("ended") { state("m1") == TransferState.CANCELLED }
        browse.onDelete(path(32, picked.id, "docs"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_OK, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
    }

    @Test fun readOnlyRootRefusesChanges() = runBlocking {
        val tree = FakeTree(other, entries = listOf(file("a.txt")))
        val browse = service(tree)
        browse.onMkdir(path(1, other.id, "new"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_DENIED, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        browse.onDelete(path(2, other.id, "a.txt"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_DENIED, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        browse.onRename(rename(3, other.id, "a.txt", "b.txt"))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_DENIED, last<BrowseResult>(MessageType.BROWSE_RESULT).outcome)
        assertTrue(tree.calls.isEmpty())
        // Reading still works.
        browse.onList(list(4, other.id))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_OK, last<BrowseListing>(MessageType.BROWSE_LISTING).outcome)
    }

    @Test fun writeWithoutRoomIsRefusedNoSpace() {
        val sink = TightSink(free = 64L shl 20)
        val browse = service(FakeTree(picked, sink = sink))
        val offer = writeOffer(picked.id, "").toBuilder().setSize(1).build()
        assertEquals(SinkResult.Refused(TransferError.TRANSFER_ERROR_NO_SPACE), browse.sinkFor(offer))
        assertTrue(sink.aborted, "the part is removed")
        val fits = TightSink(free = (64L shl 20) + 10)
        val roomy = service(FakeTree(picked.copy(id = "aaaaaaaaaaaaaaaa"), sink = fits))
        val ok = writeOffer("aaaaaaaaaaaaaaaa", "").toBuilder().setSize(10).build()
        assertIs<SinkResult.Ready>(roomy.sinkFor(ok))
    }

    @Test fun rootRemovedDuringOpenCancelsTheTransfer() = runBlocking {
        val f = ClosableFile("a.txt")
        val gated = GatedTree(FakeTree(picked, readable = mapOf("a.txt" to f)))
        val browse = service(gated, FakeTree(other))
        val reading = scope.launch { browse.onRead(path(7, picked.id, "a.txt")) }
        assertTrue(gated.entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
        trees.remove(gated)
        browse.onRootsChanged()
        gated.gate.countDown()
        reading.join()
        assertTrue(f.closed, "the descriptor opened after the cancel is closed")
        assertTrue(queued.isEmpty())
        assertTrue(engine.transfers.value.isEmpty(), "no transfer was started")
        assertTrue(sent.none { it.first == MessageType.FILES_OFFER })
        val result = last<BrowseResult>(MessageType.BROWSE_RESULT)
        assertEquals(7L, result.requestId)
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, result.outcome)
    }

    @Test fun rootRemovedDuringWriteOpenRefusesTheWrite() {
        val gated = GatedTree(FakeTree(picked))
        val browse = service(gated, FakeTree(other))
        val result = java.util.concurrent.atomic.AtomicReference<SinkResult>()
        val opening = Thread { result.set(browse.sinkFor(writeOffer(picked.id, "docs"))) }.apply { start() }
        assertTrue(gated.entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
        // The pending write already counts as one under way.
        assertTrue(runBlocking { browse.onDelete(path(1, picked.id, "docs")); last<BrowseResult>(MessageType.BROWSE_RESULT).outcome } == BrowseOutcome.BROWSE_OUTCOME_EXISTS)
        trees.remove(gated)
        browse.onRootsChanged()
        gated.gate.countDown()
        opening.join(30_000)
        assertEquals(SinkResult.Refused(TransferError.TRANSFER_ERROR_BAD_TARGET), result.get())
        assertTrue(gated.inner.sink.aborted, "the part opened after the cancel is removed")
    }

    @Test fun browsingClosedDuringWriteOpenRefusesDisabled() {
        val gated = GatedTree(FakeTree(picked))
        val browse = service(gated)
        val result = java.util.concurrent.atomic.AtomicReference<SinkResult>()
        val opening = Thread { result.set(browse.sinkFor(writeOffer(picked.id, ""))) }.apply { start() }
        assertTrue(gated.entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
        browse.cancelAll()
        gated.gate.countDown()
        opening.join(30_000)
        assertEquals(SinkResult.Refused(TransferError.TRANSFER_ERROR_DISABLED), result.get())
        assertTrue(gated.inner.sink.aborted)
    }

    @Test fun closingBrowsingCancelsQueuedWrites() = runBlocking {
        val browse = service(FakeTree(picked))
        macWrite("m1", picked.id, "") // active: the receive direction is busy
        val queuedOffer = writeOffer(picked.id, "").toBuilder().setTransferId("m2").build()
        engine.onMessage(envelope(Channel.CHANNEL_FILES, 2, MessageType.FILES_OFFER, queuedOffer))
        assertEquals(TransferState.QUEUED, state("m2"))
        // A plain file for Downloads waiting its turn is not browse traffic.
        val plain = TransferOfferPlain("m3")
        engine.onMessage(envelope(Channel.CHANNEL_FILES, 3, MessageType.FILES_OFFER, plain))
        browse.cancelAll()
        awaitUntil("cancelled") { state("m1") == TransferState.CANCELLED && state("m2") == TransferState.CANCELLED }
        // m3 then gets its turn (this test's sinks refuse a plain offer, so it fails): it was not cancelled.
        awaitUntil("m3 ran") { state("m3") != TransferState.QUEUED }
        assertTrue(state("m3") != TransferState.CANCELLED)
    }

    @Test fun readDescriptorIsClosedWhenHandingItOverThrows() {
        val f = ClosableFile("a.txt")
        trees.add(FakeTree(picked, readable = mapOf("a.txt" to f)))
        val browse = BrowseService(
            roots = { trees.toList() },
            send = { type, payload -> sent.add(type to payload) },
            transfers = engine,
            onQueued = { _, _ -> throw IllegalStateException("tracking failed") },
            scope = scope,
            io = Dispatchers.IO,
        )
        val thrown = runCatching { runBlocking { browse.onRead(path(3, picked.id, "a.txt")) } }.exceptionOrNull()
        assertIs<IllegalStateException>(thrown)
        assertTrue(f.closed, "the descriptor is not leaked")
    }

    @Test fun freeSpaceThatCantBeReadIsUnknownRoom() {
        val sink = BlindSink()
        val browse = service(FakeTree(picked, sink = sink))
        val result = runCatching { browse.sinkFor(writeOffer(picked.id, "")) }
        assertIs<SinkResult.Ready>(result.getOrNull(), "the write goes ahead, as with no figure")
        assertFalse(sink.aborted)
    }

    private fun TransferOfferPlain(id: String) = TransferOffer.newBuilder()
        .setTransferId(id).setName("plain.txt").setSize(1).setKind(TransferKind.TRANSFER_KIND_FILE).build()
}
