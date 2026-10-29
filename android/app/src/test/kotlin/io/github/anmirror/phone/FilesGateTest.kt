package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.transfer.Direction
import io.github.anmirror.transfer.TransferState
import io.github.anmirror.transfer.TransferStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FilesGateTest {
    @Test fun plainMacOfferNeedsFilesV1() {
        // R5: an offer without a target is a plain file for Downloads; browse being open is not enough.
        assertNull(offerRefusal(hasTarget = false, shared = setOf("files.v1"), browseOpen = false))
        assertEquals(
            TransferError.TRANSFER_ERROR_DISABLED,
            offerRefusal(hasTarget = false, shared = setOf("browse.v1", "photos.v1"), browseOpen = true),
        )
        assertEquals(TransferError.TRANSFER_ERROR_DISABLED, offerRefusal(hasTarget = false, shared = emptySet(), browseOpen = false))
    }

    @Test fun targetedMacOfferNeedsBrowseOpen() {
        // A browse write needs browse.v1 shared AND browse open (switch on, a root to write to).
        assertNull(offerRefusal(hasTarget = true, shared = setOf("browse.v1"), browseOpen = true))
        assertEquals(TransferError.TRANSFER_ERROR_DISABLED, offerRefusal(hasTarget = true, shared = setOf("browse.v1"), browseOpen = false))
        assertEquals(TransferError.TRANSFER_ERROR_DISABLED, offerRefusal(hasTarget = true, shared = setOf("files.v1"), browseOpen = false))
        assertEquals(TransferError.TRANSFER_ERROR_DISABLED, offerRefusal(hasTarget = true, shared = setOf("files.v1"), browseOpen = true))
    }

    @Test fun anyBulkFeatureCarriesFilesMessages() {
        for (cap in listOf("files.v1", "browse.v1", "screenshots.v1", "photos.v1")) assertTrue(bulkShared(setOf(cap)), cap)
        assertFalse(bulkShared(setOf("clipboard.v1", "share.v1")))
    }

    private fun allowed(
        kind: TransferKind,
        requestId: Long = 0,
        screenshotsOpen: Boolean = false,
        photosOpen: Boolean = false,
        browseOpen: Boolean = false,
    ) = phoneOfferAllowed(kind, requestId, screenshotsOpen = screenshotsOpen, photosOpen = photosOpen, browseOpen = browseOpen)

    @Test fun screenshotOfferNeedsScreenshotsOpen() {
        // files.v1 (or any bulk feature) shared is not enough for a screenshot.
        assertFalse(allowed(TransferKind.TRANSFER_KIND_SCREENSHOT, photosOpen = true, browseOpen = true))
        assertTrue(allowed(TransferKind.TRANSFER_KIND_SCREENSHOT, screenshotsOpen = true))
        assertTrue(allowed(TransferKind.TRANSFER_KIND_FILE))
    }

    @Test fun photoOfferNeedsPhotosOpen() {
        // files.v1 or screenshots.v1 shared is not enough for a photo (R5).
        assertFalse(allowed(TransferKind.TRANSFER_KIND_PHOTO, requestId = 9, screenshotsOpen = true, browseOpen = true))
        assertTrue(allowed(TransferKind.TRANSFER_KIND_PHOTO, requestId = 9, photosOpen = true))
    }

    @Test fun browseReadAnswerNeedsBrowseOpen() {
        // A FILE send answering a browse.read (request ID set) goes only while browse is open.
        assertFalse(allowed(TransferKind.TRANSFER_KIND_FILE, requestId = 5, screenshotsOpen = true, photosOpen = true))
        assertTrue(allowed(TransferKind.TRANSFER_KIND_FILE, requestId = 5, browseOpen = true))
        // A file the user shared (no request) is not a browse answer.
        assertTrue(allowed(TransferKind.TRANSFER_KIND_FILE, requestId = 0, browseOpen = false))
    }

    @Test fun onlyFinishedOrDroppedSharesAreReleased() {
        fun st(id: String, state: TransferState) =
            TransferStatus(id, Direction.SEND, "n", 1, 0, TransferKind.TRANSFER_KIND_FILE, state)
        val fresh = listOf(
            st("queued", TransferState.QUEUED),
            st("waiting", TransferState.WAITING),
            st("active", TransferState.ACTIVE),
            st("done", TransferState.DONE),
            st("failed", TransferState.FAILED),
            st("cancelled", TransferState.CANCELLED),
        )
        // "dropped" ended and fell off the engine's recent list.
        val tracked = listOf("queued", "waiting", "active", "done", "failed", "cancelled", "dropped")
        assertEquals(setOf("done", "failed", "cancelled", "dropped"), sharesToRelease(tracked, fresh).toSet())
    }
}
