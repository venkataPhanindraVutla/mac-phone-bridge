package io.github.anmirror.feature.mirror

import kotlin.test.Test
import kotlin.test.assertEquals

class PairingReplyTest {
    @Test
    fun replyWithoutPortUsesDiscovered() {
        assertEquals(ReplyParse.Ok(37123, "482916"), PairingReply.parse("482916", discoveredPort = 37123))
        assertEquals(ReplyParse.Ok(37123, "482916"), PairingReply.parse("  482916\n", discoveredPort = 37123))
    }

    @Test
    fun replyWithPortAndCode() {
        assertEquals(ReplyParse.Ok(37123, "482916"), PairingReply.parse("37123 482916", discoveredPort = null))
        assertEquals(ReplyParse.Ok(37123, "482916"), PairingReply.parse("37123:482916", discoveredPort = null))
        assertEquals(ReplyParse.Ok(37123, "482916"), PairingReply.parse(" 37123   482916 ", discoveredPort = null))
        // A typed port wins over the discovered one.
        assertEquals(ReplyParse.Ok(40001, "482916"), PairingReply.parse("40001 482916", discoveredPort = 37123))
    }

    @Test
    fun noPortKnownNeedsBoth() {
        assertEquals(ReplyParse.Invalid, PairingReply.parse("482916", discoveredPort = null))
    }

    @Test
    fun codeMustBeSixDigits() {
        for (bad in listOf("48291", "4829160", "48291a", "", "   ", "37123 48291", "37123:4829167", "４８２９１６", "482 916")) {
            assertEquals(ReplyParse.Invalid, PairingReply.parse(bad, discoveredPort = 37123), "\"$bad\"")
        }
    }

    @Test
    fun portOutOfRangeIsInvalid() {
        for (bad in listOf("0 482916", "65536 482916", "-1 482916", "99999999999 482916", "x 482916", "37123 482916 1")) {
            assertEquals(ReplyParse.Invalid, PairingReply.parse(bad, discoveredPort = null), "\"$bad\"")
        }
        assertEquals(ReplyParse.Ok(1, "000000"), PairingReply.parse("1 000000", discoveredPort = null))
        assertEquals(ReplyParse.Ok(65535, "999999"), PairingReply.parse("65535:999999", discoveredPort = null))
    }
}
