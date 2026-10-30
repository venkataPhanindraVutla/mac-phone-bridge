package io.github.anmirror.adb

import java.io.EOFException
import java.io.IOException
import java.net.ConnectException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLException
import kotlin.test.Test
import kotlin.test.assertEquals

/** Where libadb's pairing failed, read from the exception it threw (see [pairingStage]). */
class PairingStageTest {
    private fun frames(vararg methods: String) = methods.map {
        StackTraceElement(PAIRING_CTX_CLASS, it, "PairingConnectionCtx.java", 1)
    }.toTypedArray()

    private fun <T : Throwable> T.at(vararg methods: String): T = apply { stackTrace = frames(*methods) }

    @Test
    fun refusedIsNotListening() {
        val e = ConnectException("Connection refused").at("setupTlsConnection", "start")
        assertEquals(AdbPairingException.Stage.NOT_LISTENING, pairingStage(e))
    }

    @Test
    fun tlsFailureIsHandshake() {
        val e = SSLHandshakeException("Connection closed by peer").at("setupTlsConnection", "start")
        assertEquals(AdbPairingException.Stage.HANDSHAKE, pairingStage(e))
    }

    @Test
    fun failedExchangeIsAfterHandshake() {
        assertEquals(AdbPairingException.Stage.AFTER_HANDSHAKE, pairingStage(IOException("Could not exchange peer info.").at("start")))
        assertEquals(AdbPairingException.Stage.AFTER_HANDSHAKE, pairingStage(EOFException().at("readHeader", "doExchangePeerInfo", "start")))
        // An SSLException after the handshake (the daemon hangs up on a wrong code) is not a handshake failure.
        assertEquals(AdbPairingException.Stage.AFTER_HANDSHAKE, pairingStage(SSLException("reset").at("readHeader", "doExchangeMsgs", "start")))
    }

    @Test
    fun causeChainIsSearched() {
        val inner = ConnectException("Connection refused").at("setupTlsConnection")
        assertEquals(AdbPairingException.Stage.NOT_LISTENING, pairingStage(IOException("wrapped", inner).at("pair")))
    }
}
