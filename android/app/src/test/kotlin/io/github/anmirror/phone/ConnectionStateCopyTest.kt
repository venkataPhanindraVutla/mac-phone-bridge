package io.github.anmirror.phone

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PairingFailure
import io.github.anmirror.connection.PhoneConnectionState
import kotlin.test.Test
import kotlin.test.assertEquals

class ConnectionStateCopyTest {
    private val mac = PairedMac("ab", "Mac", "ab", ByteArray(32), "10.0.0.5", 4000, 0)

    @Test
    fun problemStatesHaveTheirOwnCopy() {
        assertEquals(R.string.state_not_recognized, PhoneConnectionState.NotRecognized(mac).messageRes())
        assertEquals(R.string.state_busy, PhoneConnectionState.Busy(mac).messageRes())
        assertEquals(R.string.state_incompatible, PhoneConnectionState.Incompatible(mac).messageRes())
        // Unreachable reuses the pairing copy for an unreachable Mac.
        assertEquals(PairingFailure.UNREACHABLE.messageRes(), PhoneConnectionState.Unreachable(mac).messageRes())
    }

    @Test
    fun connectedAndLookingNameTheMac() {
        assertEquals(R.string.state_connected, PhoneConnectionState.Connected(mac, emptySet()).messageRes())
        assertEquals(R.string.state_looking, PhoneConnectionState.Connecting(mac).messageRes())
        assertEquals(R.string.state_looking, PhoneConnectionState.Searching.messageRes())
    }

    @Test
    fun forgetCopyDependsOnConnection() {
        // R37 #4: only a connected Mac hears the goodbye and forgets this phone too.
        assertEquals(R.string.home_forget_body_connected, PhoneConnectionState.Connected(mac, emptySet()).forgetBodyRes())
        for (s in listOf(
            PhoneConnectionState.Connecting(mac),
            PhoneConnectionState.Searching,
            PhoneConnectionState.Unreachable(mac),
            PhoneConnectionState.NotRecognized(mac),
            PhoneConnectionState.Busy(mac),
            PhoneConnectionState.Incompatible(mac),
            PhoneConnectionState.Stopped,
        )) {
            assertEquals(R.string.home_forget_body_not_connected, s.forgetBodyRes(), "$s")
        }
    }
}
