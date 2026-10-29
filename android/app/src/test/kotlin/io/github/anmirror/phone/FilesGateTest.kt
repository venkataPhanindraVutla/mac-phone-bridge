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
        // R5: an offer without a target is a plain file for Downloads.
        assertNull(offerRefusal(hasTarget = false, shared = setOf("files.v1")))
        assertEquals(TransferError.TRANSFER_ERROR_DISABLED, offerRefusal(hasTarget = false, shared = setOf("browse.v1", "photos.v1")))
        assertEquals(TransferError.TRANSFER_ERROR_DISABLED, offerRefusal(hasTarget = false, shared = emptySet()))
    }

    @Test fun targetedMacOfferNeedsBrowseV1() {
        assertNull(offerRefusal(hasTarget = true, shared = setOf("browse.v1")))
        assertEquals(TransferError.TRANSFER_ERROR_DISABLED, offerRefusal(hasTarget = true, shared = setOf("files.v1")))
    }

    @Test fun anyBulkFeatureCarriesFilesMessages() {
        for (cap in listOf("files.v1", "browse.v1", "screenshots.v1", "photos.v1")) assertTrue(bulkShared(setOf(cap)), cap)
        assertFalse(bulkShared(setOf("clipboard.v1", "share.v1")))
    }

    @Test fun screenshotOfferNeedsScreenshotsOpen() {
        // files.v1 (or any bulk feature) shared is not enough for a screenshot.
        assertFalse(phoneOfferAllowed(TransferKind.TRANSFER_KIND_SCREENSHOT, screenshotsOpen = false))
        assertTrue(phoneOfferAllowed(TransferKind.TRANSFER_KIND_SCREENSHOT, screenshotsOpen = true))
        assertTrue(phoneOfferAllowed(TransferKind.TRANSFER_KIND_FILE, screenshotsOpen = false))
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
