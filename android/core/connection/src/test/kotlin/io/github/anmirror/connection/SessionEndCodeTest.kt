package io.github.anmirror.connection

import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.envelope
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Goodbye
import io.github.anmirror.protocol.v1.GoodbyeReason
import io.github.anmirror.protocol.v1.Ping
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.io.IOException
import java.net.SocketException
import java.security.ProviderException
import java.security.SignatureException
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Why a session ended, as the content-free code the phone's event log records (I3). */
@OptIn(ExperimentalCoroutinesApi::class)
class SessionEndCodeTest {
    private class Rig(scope: TestScope, shared: Set<String> = CAPS.toSet()) {
        private val wires = MemoryWire.pair()
        val macWire: MemoryWire = wires.second
        val mac = ControlChannel(wires.second, "h", 1, Identities.PHONE_FP)
        val phone = ControlChannel(wires.first, "h", 1, Identities.MAC_FP)
        val session = PhoneSession(phone, shared, uptimeMs = { scope.testScheduler.currentTime })
        val macPings = AtomicInteger()
        val end: Deferred<SessionEnd> = scope.backgroundScope.async {
            session.run(onMacPing = { macPings.incrementAndGet() }) { }
        }
    }

    @Test
    fun peerCloseIsEof() = runTest {
        val r = Rig(this)
        runCurrent()
        r.mac.close()
        runCurrent()
        assertEquals(SessionEnd.CLOSED, r.end.await())
        assertEquals("EOF", r.session.endCode)
    }

    @Test
    fun localCloseIsLocalClose() = runTest {
        val r = Rig(this)
        runCurrent()
        r.phone.close()
        runCurrent()
        assertEquals(SessionEnd.CLOSED, r.end.await())
        assertEquals("LOCAL_CLOSE", r.session.endCode)
    }

    @Test
    fun goodbyeCarriesItsReason() = runTest {
        val r = Rig(this)
        runCurrent()
        r.mac.send(Channel.CHANNEL_SYSTEM, MessageType.GOODBYE, Goodbye.newBuilder().setReason(GoodbyeReason.GOODBYE_REASON_SHUTDOWN).build())
        runCurrent()
        assertEquals(SessionEnd.GOODBYE, r.end.await())
        assertEquals("GOODBYE_SHUTDOWN", r.session.endCode)
    }

    @Test
    fun missingPongIsPingTimeout() = runTest {
        val r = Rig(this)
        advanceTimeBy(40_001)
        runCurrent()
        assertEquals(SessionEnd.PONG_TIMEOUT, r.end.await())
        assertEquals("PING_TIMEOUT", r.session.endCode)
    }

    @Test
    fun transportErrorsNameTheirClass() = runTest {
        val tls = Rig(this)
        val io = Rig(this)
        runCurrent()
        tls.macWire.abort(SSLException("Received fatal alert: bad_record_mac"))
        io.macWire.abort(SocketException("Connection reset"))
        runCurrent()
        assertEquals("TLS_SSLException", tls.session.endCode)
        assertEquals("IO_SocketException", io.session.endCode)
    }

    @Test
    fun codesAreLogSafe() {
        assertEquals("GOODBYE_UNPAIRED", SessionEndCode.goodbye(GoodbyeReason.GOODBYE_REASON_UNPAIRED))
        assertEquals("GOODBYE_UNKNOWN", SessionEndCode.goodbye(null))
        assertEquals("IO_IOException", SessionEndCode.of(IOException("10.0.0.5 refused")), "the message never goes in")
        assertEquals("ERR_Unknown", SessionEndCode.of(object : RuntimeException() {}))
        assertEquals(
            "EOF,matured=true,liveness=false,s=61",
            SessionEndCode.logDetail("EOF", connectedMs = 61_000, liveness = false),
        )
        assertEquals("PING_TIMEOUT,matured=false,liveness=true,s=59", SessionEndCode.logDetail("PING_TIMEOUT", 59_999, true))
    }

    /** T4-M4: a Mac ping whose pong could not be written is not counted as answered. */
    @Test
    fun macPingIsCountedOnlyWhenThePongWasWritten() = runTest {
        val r = Rig(this, (CAPS + LIVENESS_CAPABILITY).toSet())
        runCurrent()
        r.macWire.write(envelope(Channel.CHANNEL_SYSTEM, 7, MessageType.PING, Ping.getDefaultInstance()))
        runCurrent()
        assertEquals(1, r.macPings.get())
        // The ping arrives, then the connection is gone before the pong can go out.
        r.macWire.write(envelope(Channel.CHANNEL_SYSTEM, 8, MessageType.PING, Ping.getDefaultInstance()))
        r.macWire.close()
        runCurrent()
        assertTrue(r.end.isCompleted)
        assertEquals(1, r.macPings.get())
    }

    /** M4: a local Keystore failure while signing during the handshake is not the Mac refusing us. */
    @Test
    fun localKeyFailureIsNotARefusal() {
        val signing = SSLHandshakeException("Cannot produce CertificateVerify signature").apply { initCause(SignatureException("keystore busy")) }
        val provider = SSLException("handshake failed", ProviderException("Keystore operation failed"))
        val boring = SSLHandshakeException("Read error: ssl=0x7b: Failure in SSL library: error:1000044e:SSL routines:OPENSSL_internal:PRIVATE_KEY_OPERATION_FAILED")
        val alert = SSLHandshakeException("Received fatal alert: certificate_required")
        assertFalse(isRefusalByPeer(signing, pinMatched = true))
        assertFalse(isRefusalByPeer(provider, pinMatched = true))
        assertFalse(isRefusalByPeer(boring, pinMatched = true))
        assertTrue(isRefusalByPeer(alert, pinMatched = true))
        assertTrue(isRefusalByPeer(SocketException("Connection reset"), pinMatched = true))
        assertFalse(isRefusalByPeer(alert, pinMatched = false))
        assertFalse(isRefusalByPeer(java.net.SocketTimeoutException("Read timed out"), pinMatched = true))
    }
}
