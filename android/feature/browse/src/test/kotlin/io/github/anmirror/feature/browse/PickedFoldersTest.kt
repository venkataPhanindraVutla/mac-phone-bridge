package io.github.anmirror.feature.browse

import kotlin.test.Test
import kotlin.test.assertEquals

class PickedFoldersTest {
    @Test fun rootIdIsFirst16HexOfSha256OfTreeUri() {
        // printf %s '<uri>' | shasum -a 256 | cut -c1-16
        assertEquals("8794949a00b779d7", PickedFolders.rootId("content://com.android.externalstorage.documents/tree/primary%3ADocuments"))
    }
}
