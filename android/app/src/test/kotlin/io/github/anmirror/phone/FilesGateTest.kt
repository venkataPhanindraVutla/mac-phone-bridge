package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.TransferError
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
}
