package io.github.anmirror.feature.share

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ShareClassifierTest {
    @Test fun streamsAreFiles() {
        assertEquals(Outgoing.Files, ShareClassifier.classify(null, 1))
        // Streams win over any text that came with them (often a caption or the file's name).
        assertEquals(Outgoing.Files, ShareClassifier.classify("https://example.com", 3))
    }

    @Test fun loneHttpsUrlIsLink() {
        assertEquals(Outgoing.Link("https://example.com/a?b=c#d"), ShareClassifier.classify("https://example.com/a?b=c#d", 0))
        // Trimmed, and plain http counts too.
        assertEquals(Outgoing.Link("http://example.com"), ShareClassifier.classify("  http://example.com\n", 0))
        assertEquals("HTTPS://Example.com/x", ShareClassifier.linkOrNull("HTTPS://Example.com/x"))
    }

    @Test fun urlInsideSentenceIsText() {
        val sentence = "Look at this https://example.com"
        assertEquals(Outgoing.Text(sentence), ShareClassifier.classify(sentence, 0))
        assertEquals(Outgoing.Text("Title\nhttps://example.com"), ShareClassifier.classify("Title\nhttps://example.com", 0))
    }

    @Test fun ftpAndJavascriptAreText() {
        for (s in listOf("ftp://example.com/file", "javascript:alert(1)", "file:///etc/passwd", "https:///no-host", "example.com")) {
            assertNull(ShareClassifier.linkOrNull(s), s)
            assertEquals(Outgoing.Text(s), ShareClassifier.classify(s, 0))
        }
    }

    @Test fun overlongUrlIsText() {
        val prefix = "https://example.com/"
        val atCap = prefix + "a".repeat(8_192 - prefix.length)
        assertEquals(atCap, ShareClassifier.linkOrNull(atCap))
        val over = atCap + "a"
        assertNull(ShareClassifier.linkOrNull(over))
        assertEquals(Outgoing.Text(over), ShareClassifier.classify(over, 0))
        // The cap is in UTF-8 bytes, not characters.
        val wide = prefix + "%C3%A9" + "é".repeat((8_192 - prefix.length - 6) / 2 + 1)
        assertNull(ShareClassifier.linkOrNull(wide))
    }

    @Test fun blankIsNothing() {
        assertEquals(Outgoing.Nothing, ShareClassifier.classify(null, 0))
        assertEquals(Outgoing.Nothing, ShareClassifier.classify("", 0))
        assertEquals(Outgoing.Nothing, ShareClassifier.classify(" \n\t", 0))
    }
}
