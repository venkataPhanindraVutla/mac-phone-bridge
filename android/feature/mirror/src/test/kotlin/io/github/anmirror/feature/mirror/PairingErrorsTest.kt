package io.github.anmirror.feature.mirror

import io.github.anmirror.adb.AdbPairingException
import io.github.anmirror.adb.AdbPairingException.Stage
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLHandshakeException
import kotlin.test.Test
import kotlin.test.assertEquals

class PairingErrorsTest {
    @Test
    fun connectPortGivesWrongPort() {
        // Whatever failed, the user typed the port Wireless debugging connects on.
        val e = AdbPairingException(Stage.AFTER_HANDSHAKE, null)
        assertEquals(PairingError.WRONG_PORT, PairingErrors.classify(e, port = 41000, knownConnectPort = 41000))
        assertEquals(PairingError.WRONG_PORT, PairingErrors.classify(SocketTimeoutException(), port = 41000, knownConnectPort = 41000))
    }

    @Test
    fun handshakeFailureGivesWrongPort() {
        val e = AdbPairingException(Stage.HANDSHAKE, SSLHandshakeException("closed"))
        assertEquals(PairingError.WRONG_PORT, PairingErrors.classify(e, port = 37123, knownConnectPort = 41000))
    }

    @Test
    fun failureAfterHandshakeGivesWrongCode() {
        val e = AdbPairingException(Stage.AFTER_HANDSHAKE, IOException("Could not exchange peer info."))
        assertEquals(PairingError.WRONG_CODE, PairingErrors.classify(e, port = 37123, knownConnectPort = null))
    }

    @Test
    fun refusedGivesNotListening() {
        val e = AdbPairingException(Stage.NOT_LISTENING, ConnectException("Connection refused"))
        assertEquals(PairingError.NOT_LISTENING, PairingErrors.classify(e, port = 37123, knownConnectPort = null))
        // Unwrapped, as from a client that does not set the stage.
        assertEquals(PairingError.NOT_LISTENING, PairingErrors.classify(ConnectException("refused"), port = 37123, knownConnectPort = null))
    }

    @Test
    fun timeoutGivesTimeout() {
        assertEquals(PairingError.TIMEOUT, PairingErrors.classify(SocketTimeoutException("pairing timed out"), port = 37123, knownConnectPort = null))
        val wrapped = AdbPairingException(Stage.HANDSHAKE, SocketTimeoutException("read timed out"))
        assertEquals(PairingError.TIMEOUT, PairingErrors.classify(wrapped, port = 37123, knownConnectPort = null))
    }
}
