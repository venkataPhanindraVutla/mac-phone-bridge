package io.github.anmirror.adb

import io.github.anmirror.adb.AdbPairingException.Stage
import java.io.EOFException
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Ruling R46: the stage comes from what is known about the failure, not from where it was thrown. */
class PairingStageTest {
    @Test
    fun refusedIsNotListening() {
        assertEquals(Stage.NOT_LISTENING, pairingStage(ConnectException("Connection refused")))
        assertEquals(Stage.NOT_LISTENING, pairingStage(NoRouteToHostException("No route to host")))
        assertEquals(Stage.NOT_LISTENING, pairingStage(IOException("wrapped", ConnectException("Connection refused"))))
    }

    @Test
    fun libadbExchangeFailuresAreAfterHandshake() {
        assertEquals(Stage.AFTER_HANDSHAKE, pairingStage(EOFException()))
        assertEquals(Stage.AFTER_HANDSHAKE, pairingStage(IOException("Could not exchange peer info.")))
        assertEquals(Stage.AFTER_HANDSHAKE, pairingStage(IOException("Exchanging message wasn't successful.")))
        assertEquals(Stage.AFTER_HANDSHAKE, pairingStage(IOException("x", IllegalStateException("Unable to initialize pairing cipher"))))
    }

    @Test
    fun anythingElseOnAnAnsweringPortIsHandshake() {
        // The JDK's dropped handshake carries an EOF inside the handshake failure: not a code failure.
        assertEquals(Stage.HANDSHAKE, pairingStage(SSLHandshakeException("Remote host terminated the handshake").apply { initCause(EOFException()) }))
        assertEquals(Stage.HANDSHAKE, pairingStage(SocketException("Connection reset")))
        assertEquals(Stage.HANDSHAKE, pairingStage(SSLException("Read error: Connection reset by peer")))
        assertEquals(Stage.HANDSHAKE, pairingStage(IOException("Unable to create PairingAuthCtx.")))
    }

    @Test
    fun framesAreOnlyAHint() {
        fun at(vararg methods: String) = IOException("x").apply {
            stackTrace = methods.map { StackTraceElement(PAIRING_CTX_CLASS, it, "PairingConnectionCtx.java", 1) }.toTypedArray()
        }
        assertEquals(Stage.HANDSHAKE, framesHint(at("setupTlsConnection", "start")))
        assertEquals(Stage.AFTER_HANDSHAKE, framesHint(at("doExchangePeerInfo", "start")))
        assertNull(framesHint(IOException("no libadb frames").apply { stackTrace = emptyArray() }))
        // The hint never decides: a failure inside the exchange that matches no known signal is still HANDSHAKE.
        assertEquals(Stage.HANDSHAKE, pairingStage(at("doExchangePeerInfo", "start")))
    }
}
