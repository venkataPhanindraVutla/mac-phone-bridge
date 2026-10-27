package io.github.anmirror.connection

import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Pong
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue

class TlsConnectorTest {
    private fun closedPort(): Int = ServerSocket(0).use { it.localPort }

    @Test
    fun negotiatesTls13AndPresentsPhoneCertificate() = runBlocking {
        val protocol = AtomicReference<String>()
        val peer = AtomicReference<String>()
        TestMacServer { c ->
            protocol.set(c.socket.session.protocol)
            peer.set(c.peerFingerprintHex)
            c.answerHello()
            val ping = c.expect(MessageType.PING)
            c.send(Channel.CHANNEL_SYSTEM, MessageType.PONG, Pong.getDefaultInstance(), ping.id)
        }.use { server ->
            val channel = withTimeout(10_000) {
                TlsConnector(Identities.phone).connect(listOf("127.0.0.1"), server.port, Identities.MAC_FP)
            }
            assertEquals(Identities.MAC_FP, channel.peerFingerprintHex)
            assertEquals("127.0.0.1", channel.host)
            assertEquals(server.port, channel.port)
            assertIs<HelloResult.Ok>(exchangeHello(channel, phoneHello()))
            val pingId = channel.send(Channel.CHANNEL_SYSTEM, MessageType.PING, io.github.anmirror.protocol.v1.Ping.getDefaultInstance())
            assertEquals(2L, pingId, "ids count up from 1 per connection")
            val pong = withTimeout(5_000) { channel.receive() }
            assertEquals(MessageType.PONG, pong?.type)
            assertEquals(pingId, pong?.replyTo)
            channel.close()
            server.join()
            assertEquals("TLSv1.3", protocol.get())
            assertEquals(Identities.PHONE_FP, peer.get())
        }
    }

    @Test
    fun rejectsServerWithWrongFingerprint() = runBlocking {
        TestMacServer(identity = Identities.stranger) { _ -> }.use { server ->
            val e = assertFailsWith<UnreachableException> {
                withTimeout(10_000) {
                    TlsConnector(Identities.phone).connect(listOf("127.0.0.1"), server.port, Identities.MAC_FP)
                }
            }
            assertEquals(listOf("127.0.0.1"), e.tried)
            assertEquals(0, server.scriptsStarted.get(), "the handshake must not complete")
        }
    }

    @Test
    fun connectsViaSecondHostWhenFirstUnreachable() = runBlocking {
        TestMacServer { c -> c.answerHello() }.use { server ->
            val started = System.nanoTime()
            val channel = withTimeout(10_000) {
                // 10.255.255.1 black-holes (or fails fast with "no route"); either way the
                // phone moves on to the second host within the 3 s per-host budget.
                TlsConnector(Identities.phone).connect(listOf("10.255.255.1", "127.0.0.1"), server.port, Identities.MAC_FP)
            }
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            assertEquals("127.0.0.1", channel.host)
            assertIs<HelloResult.Ok>(exchangeHello(channel, phoneHello()))
            assertTrue(elapsedMs < 4_500, "took $elapsedMs ms")
            channel.close()
            server.join()
        }
    }

    @Test
    fun throwsUnreachableWithEveryHostTried() = runBlocking {
        val port = closedPort()
        val e = assertFailsWith<UnreachableException> {
            withTimeout(10_000) {
                TlsConnector(Identities.phone).connect(listOf("127.0.0.1", "localhost"), port, Identities.MAC_FP)
            }
        }
        assertEquals(listOf("127.0.0.1", "localhost"), e.tried)
    }

    @Test
    fun serverRefusingPhoneCertificateIsReportedAsRefusal() = runBlocking {
        // TLS 1.3: the server judges the client certificate after the client has sent its
        // last flight, so the refusal shows up either while the handshake is still writing
        // (the connector then reports refusedByPeer) or on the first read (NOT_PAIRED).
        TestMacServer(allowedClients = setOf(Identities.STRANGER_FP)) { _ -> }.use { server ->
            repeat(5) {
                val outcome = withTimeout(10_000) {
                    try {
                        val channel = TlsConnector(Identities.phone)
                            .connect(listOf("127.0.0.1", "localhost"), server.port, Identities.MAC_FP)
                        (exchangeHello(channel, phoneHello()) as HelloResult.Failed).reason
                    } catch (e: UnreachableException) {
                        assertTrue(e.refusedByPeer, "pin matched, so this is a refusal: $e")
                        assertEquals(listOf("127.0.0.1"), e.tried, "stops at the Mac that refused")
                        HelloFailure.NOT_PAIRED
                    }
                }
                assertEquals(HelloFailure.NOT_PAIRED, outcome)
            }
        }
    }

    @Test
    fun pinMismatchIsNotARefusal() = runBlocking {
        TestMacServer(identity = Identities.stranger) { _ -> }.use { server ->
            val e = assertFailsWith<UnreachableException> {
                TlsConnector(Identities.phone).connect(listOf("127.0.0.1", "localhost"), server.port, Identities.MAC_FP)
            }
            assertEquals(false, e.refusedByPeer)
            assertEquals(listOf("127.0.0.1", "localhost"), e.tried)
        }
    }

    @Test
    fun notPairedErrorOnHello() = runBlocking {
        TestMacServer(allowedClients = setOf(Identities.STRANGER_FP)) { c ->
            c.expect(MessageType.HELLO)
            c.sendError(io.github.anmirror.protocol.v1.ErrorCode.ERROR_CODE_NOT_PAIRED)
        }.use { server ->
            val result = withTimeout(10_000) {
                val channel = TlsConnector(Identities.stranger).connect(listOf("127.0.0.1"), server.port, Identities.MAC_FP)
                exchangeHello(channel, phoneHello())
            }
            assertEquals(HelloResult.Failed(HelloFailure.NOT_PAIRED), result)
            server.join()
        }
    }

    @Test
    fun helloWithOtherProtocolVersionIsMismatch() = runBlocking {
        TestMacServer { c ->
            val hello = c.expect(MessageType.HELLO)
            c.send(Channel.CHANNEL_SYSTEM, MessageType.HELLO, macHello(version = 2), hello.id)
            // SPEC 3: the receiver answers PROTOCOL_MISMATCH and closes.
            val err = c.expect(MessageType.ERROR)
            check(io.github.anmirror.protocol.v1.Error.parseFrom(err.payload).code ==
                io.github.anmirror.protocol.v1.ErrorCode.ERROR_CODE_PROTOCOL_MISMATCH)
        }.use { server ->
            val result = withTimeout(10_000) {
                val channel = TlsConnector(Identities.phone).connect(listOf("127.0.0.1"), server.port, Identities.MAC_FP)
                exchangeHello(channel, phoneHello())
            }
            assertEquals(HelloResult.Failed(HelloFailure.PROTOCOL_MISMATCH), result)
            server.join()
        }
    }

    @Test
    fun helloReplyTimesOut() = runBlocking {
        TestMacServer { c -> c.expect(MessageType.HELLO); c.awaitEof() }.use { server ->
            val result = withTimeout(10_000) {
                val channel = TlsConnector(Identities.phone).connect(listOf("127.0.0.1"), server.port, Identities.MAC_FP)
                exchangeHello(channel, phoneHello(), timeoutMs = 300)
            }
            assertEquals(HelloResult.Failed(HelloFailure.TIMED_OUT), result)
            server.join()
        }
    }

    @Test
    fun pinnedTrustManagerComparesLowercaseHexOfLeaf() {
        val tm = PinnedTrustManager(setOf(Identities.MAC_FP))
        val cert = (Identities.mac as Pkcs12Identity).certificate
        tm.checkServerTrusted(arrayOf(cert), "ECDHE_ECDSA")
        assertFailsWith<java.security.cert.CertificateException> {
            PinnedTrustManager(setOf(Identities.PHONE_FP)).checkServerTrusted(arrayOf(cert), "ECDHE_ECDSA")
        }
        assertFailsWith<java.security.cert.CertificateException> { tm.checkServerTrusted(arrayOf(), "ECDHE_ECDSA") }
        assertEquals(0, tm.acceptedIssuers.size)
        // Pins given in uppercase still match (stored form is lowercase hex).
        PinnedTrustManager(setOf(Identities.MAC_FP.uppercase())).checkClientTrusted(arrayOf(cert), "EC")
    }
}
