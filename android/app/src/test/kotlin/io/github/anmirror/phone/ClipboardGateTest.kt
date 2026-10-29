package io.github.anmirror.phone

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PhoneConnectionState
import kotlin.test.Test
import kotlin.test.assertEquals

class ClipboardGateTest {
    private val mac = PairedMac("ab", "Mac", "ab", ByteArray(32), "10.0.0.5", 4000, 0)
    private val sharing = PhoneConnectionState.Connected(mac, setOf("status.v1", "clipboard.v1"))
    private val notSharing = PhoneConnectionState.Connected(mac, setOf("status.v1"))

    @Test fun connectedSharedAndOnIsOpen() {
        assertEquals(ClipboardGate.OPEN, clipboardGate(sharing, on = true))
    }

    @Test fun connectedWithSwitchOffIsOff() {
        assertEquals(ClipboardGate.OFF, clipboardGate(sharing, on = false))
        assertEquals(ClipboardGate.OFF, clipboardGate(notSharing, on = false))
    }

    @Test fun notConnectedOrNotSharedIsNotConnected() {
        assertEquals(ClipboardGate.NOT_CONNECTED, clipboardGate(PhoneConnectionState.Unreachable(mac), on = true))
        assertEquals(ClipboardGate.NOT_CONNECTED, clipboardGate(PhoneConnectionState.Unreachable(mac), on = false))
        assertEquals(ClipboardGate.NOT_CONNECTED, clipboardGate(notSharing, on = true))
    }
}
