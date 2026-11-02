package io.github.anmirror.connection

import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.PairingCrypto
import io.github.anmirror.protocol.PairingUri
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.ErrorCode
import io.github.anmirror.protocol.v1.PairComplete
import io.github.anmirror.protocol.v1.PairConfirm
import io.github.anmirror.protocol.v1.PairRequest
import io.github.anmirror.protocol.v1.PairVerified
import com.google.protobuf.ByteString
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PairingClientTest {
    private val secret = ByteArray(32) { (it * 7).toByte() }
    private val discoveryKey = ByteArray(32) { (100 + it).toByte() }
    private val macFp = Identities.MAC_FP.unhex()
    private val phoneFp = Identities.PHONE_FP.unhex()

    private fun uri(port: Int, hosts: List<String> = listOf("127.0.0.1")) =
        PairingUri(1, macFp, secret, hosts, port, "QR Mac")

    private fun client(verifyTimeoutMs: Long = 10_000, confirmTimeoutMs: Long = 60_000) =
        PhonePairingClient(
            TlsConnector(Identities.phone), Identities.phone, "Test Phone", "Pixel Test",
            verifyTimeoutMs = verifyTimeoutMs, confirmTimeoutMs = confirmTimeoutMs, clock = { 1_700_000_000_000 },
        )

    private fun confirm(accepted: Boolean) = PairConfirm.newBuilder().setAccepted(accepted).build()

    /** Mac side up to and including pairing.verified; returns the request. */
    private fun MacConn.verify(): PairRequest {
        val env = expect(MessageType.PAIR_REQUEST)
        val request = PairRequest.parseFrom(env.payload)
        send(Channel.CHANNEL_PAIRING, MessageType.PAIR_VERIFIED, PairVerified.getDefaultInstance(), env.id)
        return request
    }

    @Test
    fun pairsAndReturnsMacWithDiscoveryKey() = runBlocking {
        val request = AtomicReference<PairRequest>()
        TestMacServer { c ->
            request.set(c.verify())
            c.send(Channel.CHANNEL_PAIRING, MessageType.PAIR_CONFIRM, confirm(true))
            val phoneConfirm = PairConfirm.parseFrom(c.expect(MessageType.PAIR_CONFIRM).payload)
            check(phoneConfirm.accepted) { "phone did not accept" }
            c.send(
                Channel.CHANNEL_PAIRING, MessageType.PAIR_COMPLETE,
                PairComplete.newBuilder().setDiscoveryKey(ByteString.copyFrom(discoveryKey)).setMacName("Ada’s Mac").build(),
            )
            c.answerHello()
        }.use { server ->
            var shown: String? = null
            val result = withTimeout(15_000) {
                client().pair(uri(server.port, listOf("127.0.0.1"))) { code -> shown = code; true }
            }
            val paired = assertIs<PairingResult.Paired>(result)
            assertEquals(Identities.MAC_FP, paired.mac.id)
            assertEquals(Identities.MAC_FP, paired.mac.fingerprintHex)
            assertContentEquals(discoveryKey, paired.mac.discoveryKey)
            assertEquals("Ada’s Mac", paired.mac.name)
            assertEquals("127.0.0.1", paired.mac.lastHost)
            assertEquals(server.port, paired.mac.lastPort)
            assertEquals(1_700_000_000_000, paired.mac.lastConnectedAt)
            assertEquals(PairingCrypto.confirmationCode(macFp, phoneFp), shown)

            // The proof binds the secret to both fingerprints (SPEC 5.1).
            val r = request.get()
            assertEquals(1, r.protocolVersion)
            assertContentEquals(PairingCrypto.secretProof(secret, macFp, phoneFp), r.secretProof.toByteArray())
            assertEquals("Test Phone", r.deviceName)
            assertEquals("Pixel Test", r.deviceModel)

            // SPEC 5.3 step 6: hello follows on the same connection.
            val hello = assertIs<HelloResult.Ok>(exchangeHello(paired.channel, phoneHello()))
            assertEquals(setOf("find.v1", "status.v1"), hello.shared)
            paired.channel.close()
            server.join()
        }
    }

    @Test
    fun expiredSecretMapsToExpired() = runBlocking {
        TestMacServer { c ->
            c.expect(MessageType.PAIR_REQUEST)
            c.sendError(ErrorCode.ERROR_CODE_PAIRING_EXPIRED)
        }.use { server ->
            var asked = false
            val result = withTimeout(15_000) { client().pair(uri(server.port)) { asked = true; true } }
            assertEquals(PairingResult.Failed(PairingFailure.EXPIRED), result)
            assertTrue(!asked, "no code is shown for an expired secret")
            server.join()
        }
    }

    @Test
    fun badSecretMapsToBadSecret() = runBlocking {
        TestMacServer { c ->
            c.expect(MessageType.PAIR_REQUEST)
            c.sendError(ErrorCode.ERROR_CODE_BAD_PAIRING_SECRET)
        }.use { server ->
            val result = withTimeout(15_000) { client().pair(uri(server.port)) { true } }
            assertEquals(PairingResult.Failed(PairingFailure.BAD_SECRET), result)
            server.join()
        }
    }

    @Test
    fun declineOnPhoneSendsConfirmFalse() = runBlocking {
        val phoneAccepted = AtomicReference<Boolean>()
        val closed = AtomicReference<Boolean>()
        TestMacServer { c ->
            c.verify()
            phoneAccepted.set(PairConfirm.parseFrom(c.expect(MessageType.PAIR_CONFIRM).payload).accepted)
            closed.set(c.awaitEof())
        }.use { server ->
            val result = withTimeout(15_000) { client().pair(uri(server.port)) { false } }
            assertEquals(PairingResult.Failed(PairingFailure.REJECTED), result)
            server.join()
            assertEquals(false, phoneAccepted.get())
            assertEquals(true, closed.get(), "the phone closes after declining")
        }
    }

    @Test
    fun declineOnMacWhileCodeIsShownMapsToRejected() = runBlocking {
        TestMacServer { c ->
            c.verify()
            c.send(Channel.CHANNEL_PAIRING, MessageType.PAIR_CONFIRM, confirm(false))
        }.use { server ->
            val result = withTimeout(15_000) {
                // The phone's user never answers; the Mac's decline must end the wait.
                client().pair(uri(server.port)) { kotlinx.coroutines.awaitCancellation() }
            }
            assertEquals(PairingResult.Failed(PairingFailure.REJECTED), result)
            server.join()
        }
    }

    @Test
    fun confirmationTimeoutSendsConfirmFalse() = runBlocking {
        val phoneAccepted = AtomicReference<Boolean>()
        TestMacServer { c ->
            c.verify()
            phoneAccepted.set(PairConfirm.parseFrom(c.expect(MessageType.PAIR_CONFIRM).payload).accepted)
        }.use { server ->
            val result = withTimeout(15_000) {
                client(confirmTimeoutMs = 300).pair(uri(server.port)) { kotlinx.coroutines.awaitCancellation() }
            }
            assertEquals(PairingResult.Failed(PairingFailure.TIMED_OUT), result)
            server.join()
            assertEquals(false, phoneAccepted.get())
        }
    }

    @Test
    fun missingVerifiedTimesOut() = runBlocking {
        TestMacServer { c ->
            c.expect(MessageType.PAIR_REQUEST)
            c.awaitEof(60_000)
        }.use { server ->
            val started = System.nanoTime()
            val result = withTimeout(30_000) { client(verifyTimeoutMs = 300).pair(uri(server.port)) { true } }
            assertEquals(PairingResult.Failed(PairingFailure.TIMED_OUT), result)
            // The client's 300 ms, not the Mac's minute of silence: loose, so a slow runner cannot trip it.
            val tookMs = (System.nanoTime() - started) / 1_000_000
            assertTrue(tookMs in 300..20_000, "took $tookMs ms")
            server.join()
        }
    }

    @Test
    fun protocolMismatchMapsToProtocolMismatch() = runBlocking {
        TestMacServer { c ->
            c.expect(MessageType.PAIR_REQUEST)
            c.sendError(ErrorCode.ERROR_CODE_PROTOCOL_MISMATCH)
        }.use { server ->
            val result = withTimeout(15_000) { client().pair(uri(server.port)) { true } }
            assertEquals(PairingResult.Failed(PairingFailure.PROTOCOL_MISMATCH), result)
            server.join()
        }
    }

    @Test
    fun wrongMacFingerprintIsUnreachable() = runBlocking {
        // A different device answers at the QR address: the pin fails, nothing is sent.
        TestMacServer(identity = Identities.stranger) { _ -> }.use { server ->
            val result = withTimeout(15_000) { client().pair(uri(server.port)) { true } }
            assertEquals(PairingResult.Failed(PairingFailure.UNREACHABLE), result)
            assertEquals(0, server.scriptsStarted.get())
        }
    }

    @Test
    fun showCodeThrowingClosesTheConnection() = runBlocking {
        val closed = AtomicReference<Boolean>()
        TestMacServer { c ->
            c.verify()
            closed.set(c.awaitEof())
        }.use { server ->
            assertFailsWith<IllegalStateException> {
                withTimeout(15_000) { client().pair(uri(server.port)) { error("UI went away") } }
            }
            server.join()
            assertEquals(true, closed.get(), "no socket left open")
        }
    }

    @Test
    fun cancellingPairClosesTheConnection() = runBlocking {
        val closed = AtomicReference<Boolean>()
        TestMacServer { c ->
            c.verify()
            closed.set(c.awaitEof())
        }.use { server ->
            val job = launch { client().pair(uri(server.port)) { kotlinx.coroutines.awaitCancellation() } }
            kotlinx.coroutines.delay(500)
            job.cancel()
            job.join()
            server.join()
            assertEquals(true, closed.get())
        }
    }

    @Test
    fun refusalAtTlsMapsToExpired() = runBlocking {
        // A Mac with no pairing window open refuses unknown certificates in the handshake.
        TestMacServer(allowedClients = setOf(Identities.STRANGER_FP)) { _ -> }.use { server ->
            val result = withTimeout(15_000) { client().pair(uri(server.port)) { true } }
            assertEquals(PairingResult.Failed(PairingFailure.EXPIRED), result)
        }
    }

    @Test
    fun pairedMacToStringHidesDiscoveryKey() {
        val mac = PairedMac("id", "Mac", "fp", discoveryKey, null, null, 0)
        assertNull(Regex("discoveryKey=\\[").find(mac.toString()))
        assertTrue(!mac.toString().contains(discoveryKey.hex()))
    }
}
