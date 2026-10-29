package io.github.anmirror.phone

import io.github.anmirror.phone.service.TransferNotificationModel
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.transfer.Direction
import io.github.anmirror.transfer.TransferState
import io.github.anmirror.transfer.TransferStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun t(
    id: String,
    direction: Direction,
    state: TransferState,
    done: Long = 0,
    size: Long = 100,
    error: TransferError? = null,
    savedAs: String? = null,
    kind: TransferKind = TransferKind.TRANSFER_KIND_FILE,
) = TransferStatus(id, direction, "$id.bin", size, done, kind, state, error, savedAs)

class TransferNotificationModelTest {
    private val model = TransferNotificationModel()

    @Test fun oneOngoingPerDirection() {
        val views = model.update(
            listOf(
                t("a", Direction.SEND, TransferState.ACTIVE, done = 40),
                t("b", Direction.SEND, TransferState.QUEUED),
                t("c", Direction.RECEIVE, TransferState.ACTIVE, done = 5, size = 10),
            ),
            cancelledHere = emptySet(),
        )
        assertEquals(setOf(Direction.SEND, Direction.RECEIVE), views.ongoing.keys)
        val send = views.ongoing.getValue(Direction.SEND)
        assertEquals("a", send.id)
        assertEquals("a.bin", send.name)
        assertEquals(40, send.percent)
        assertEquals(1, send.waiting)
        val receive = views.ongoing.getValue(Direction.RECEIVE)
        assertEquals("c", receive.id)
        assertEquals(50, receive.percent)
        assertEquals(0, receive.waiting)
        assertTrue(views.results.isEmpty())
    }

    @Test fun burstOfFiftyGivesOneOngoingAndQueuedCount() {
        val burst = (1..50).map { t("f$it", Direction.SEND, TransferState.QUEUED) }
        // Before the first one starts, the first queued is the one shown.
        var views = model.update(burst, emptySet())
        assertEquals(1, views.ongoing.size)
        assertEquals("f1", views.ongoing.getValue(Direction.SEND).id)
        assertEquals(49, views.ongoing.getValue(Direction.SEND).waiting)
        // The engine lists the waiting one wherever it is: it is the active one.
        views = model.update(burst.take(9) + t("f10", Direction.SEND, TransferState.WAITING) + burst.drop(10), emptySet())
        assertEquals("f10", views.ongoing.getValue(Direction.SEND).id)
        assertEquals(49, views.ongoing.getValue(Direction.SEND).waiting)
        // A size of 0 is 0 %, not a division by zero.
        views = model.update(listOf(t("z", Direction.RECEIVE, TransferState.ACTIVE, size = 0)), emptySet())
        assertEquals(0, views.ongoing.getValue(Direction.RECEIVE).percent)
    }

    @Test fun terminalStatesFoldIntoOneResult() {
        model.update(
            listOf(
                t("r1", Direction.RECEIVE, TransferState.ACTIVE),
                t("r2", Direction.RECEIVE, TransferState.QUEUED),
                t("r3", Direction.RECEIVE, TransferState.QUEUED),
                t("s1", Direction.SEND, TransferState.ACTIVE),
            ),
            emptySet(),
        )
        val finished = listOf(
            t("r3", Direction.RECEIVE, TransferState.FAILED, error = TransferError.TRANSFER_ERROR_NO_SPACE),
            t("r2", Direction.RECEIVE, TransferState.DONE, savedAs = "two.bin"),
            t("r1", Direction.RECEIVE, TransferState.DONE, savedAs = "one.bin"),
            t("s1", Direction.SEND, TransferState.DONE),
        )
        var views = model.update(finished, emptySet())
        assertTrue(views.ongoing.isEmpty())
        val receive = views.results.getValue(Direction.RECEIVE)
        assertEquals(2, receive.saved)
        assertEquals(1, receive.failed)
        assertEquals("r3.bin", receive.failedName)
        assertEquals(TransferError.TRANSFER_ERROR_NO_SPACE, receive.error)
        // A finished send is not a result: nothing to show for SEND.
        assertNull(views.results[Direction.SEND])
        assertEquals(setOf(Direction.RECEIVE), views.changed)

        // The same list again posts nothing new.
        views = model.update(finished, emptySet())
        assertTrue(views.changed.isEmpty())

        // After the direction went idle, the next result starts a new batch that replaces the old one.
        views = model.update(listOf(t("r4", Direction.RECEIVE, TransferState.DONE, savedAs = "four.bin")) + finished, emptySet())
        val next = views.results.getValue(Direction.RECEIVE)
        assertEquals(1, next.saved)
        assertEquals("r4", next.savedId)
        assertEquals("four.bin", next.savedName)
        assertEquals(0, next.failed)
        assertEquals(setOf(Direction.RECEIVE), views.changed)

        // A failed send is a result.
        views = model.update(listOf(t("s2", Direction.SEND, TransferState.FAILED, error = TransferError.TRANSFER_ERROR_INTERRUPTED)), emptySet())
        assertEquals(1, views.results.getValue(Direction.SEND).failed)
        assertEquals(setOf(Direction.SEND), views.changed)
    }

    @Test fun userCancelAddsNoResult() {
        model.update(listOf(t("x", Direction.SEND, TransferState.ACTIVE), t("y", Direction.SEND, TransferState.QUEUED)), emptySet())
        val cancelled = listOf(
            t("x", Direction.SEND, TransferState.CANCELLED, error = TransferError.TRANSFER_ERROR_CANCELLED),
            t("y", Direction.SEND, TransferState.ACTIVE),
        )
        var views = model.update(cancelled, cancelledHere = setOf("x"))
        assertNull(views.results[Direction.SEND])
        assertTrue(views.changed.isEmpty())
        assertEquals("y", views.ongoing.getValue(Direction.SEND).id)
        // Cancelled by the Mac: that is news, with its reason.
        views = model.update(
            listOf(t("y", Direction.SEND, TransferState.CANCELLED, error = TransferError.TRANSFER_ERROR_CANCELLED)) + cancelled.take(1),
            cancelledHere = setOf("x"),
        )
        val send = views.results.getValue(Direction.SEND)
        assertEquals(1, send.failed)
        assertEquals(TransferError.TRANSFER_ERROR_CANCELLED, send.error)
    }

    /** R12: background auto-sends (screenshots, photos) never reach the phone's shade. */
    @Test fun screenshotTransfersAreNotShown() {
        val background = listOf(TransferKind.TRANSFER_KIND_SCREENSHOT, TransferKind.TRANSFER_KIND_PHOTO)
        var views = model.update(
            background.mapIndexed { i, k -> t("s$i", Direction.SEND, TransferState.ACTIVE, done = 10, kind = k) },
            emptySet(),
        )
        assertTrue(views.ongoing.isEmpty())
        assertTrue(views.results.isEmpty())
        views = model.update(
            background.mapIndexed { i, k ->
                t("s$i", Direction.SEND, TransferState.FAILED, error = TransferError.TRANSFER_ERROR_INTERRUPTED, kind = k)
            } + t("f", Direction.SEND, TransferState.ACTIVE),
            emptySet(),
        )
        assertTrue(views.results.isEmpty())
        assertTrue(views.changed.isEmpty())
        // A file the user shared alongside is shown as before, with no screenshot counted as waiting.
        assertEquals("f", views.ongoing.getValue(Direction.SEND).id)
        assertEquals(0, views.ongoing.getValue(Direction.SEND).waiting)
    }

    @Test fun browseTransfersAreNotShown() {
        // R16: browse read answers (request ID set) and browse writes (offer with a target) are driven from the Mac's Files tab.
        val read = t("read", Direction.SEND, TransferState.ACTIVE).copy(requestId = 7)
        val write = t("write", Direction.RECEIVE, TransferState.ACTIVE).copy(browseTarget = true)
        var views = model.update(listOf(read, write), emptySet())
        assertTrue(views.ongoing.isEmpty())
        views = model.update(
            listOf(
                read.copy(state = TransferState.FAILED, error = TransferError.TRANSFER_ERROR_INTERRUPTED),
                write.copy(state = TransferState.DONE, savedAs = "up.txt"),
            ),
            emptySet(),
        )
        assertTrue(views.ongoing.isEmpty())
        assertTrue(views.results.isEmpty())
        assertTrue(views.changed.isEmpty())

        // A file from the Mac for Downloads and a file shared from the phone still show.
        views = model.update(
            listOf(t("dl", Direction.RECEIVE, TransferState.ACTIVE), t("share", Direction.SEND, TransferState.ACTIVE)),
            emptySet(),
        )
        assertEquals(setOf(Direction.SEND, Direction.RECEIVE), views.ongoing.keys)
    }
}
