package io.github.anmirror.adb

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** Ruling R58's proof on its own, with a fake stream opener in place of a connection. */
@OptIn(ExperimentalCoroutinesApi::class)
class AdbPeerProofTest {
    private val proof = AdbPeerProof(
        component = "io.github.anmirror.phone/.full.AdbProofReceiver",
        action = "io.github.anmirror.phone.ADB_PROOF",
    )
    private val opened = mutableListOf<String>()
    private var closes = 0

    private fun pipe() = AdbPipe(InputStream.nullInputStream(), ByteArrayOutputStream()) { closes++ }

    private fun nonceOf(service: String) = FakeAdbd.nonceOf(service)!!

    @Test
    fun commandIsTheBroadcastWithA128BitNonce() {
        val a = proof.newNonce()
        val b = proof.newNonce()
        assertTrue(Regex("[0-9a-f]{32}").matches(a), a)
        assertNotEquals(a, b)
        assertEquals(
            "am broadcast -a io.github.anmirror.phone.ADB_PROOF -n io.github.anmirror.phone/.full.AdbProofReceiver --es n $a",
            proof.command(a),
        )
    }

    @Test
    fun matchingBroadcastProves() = runTest {
        val ok = proof.prove { service ->
            opened += service
            // The shell ran it: the receiver hands the nonce over.
            assertTrue(proof.deliver(nonceOf(service)))
            pipe()
        }
        assertTrue(ok)
        assertEquals(1, opened.size)
        assertTrue(opened[0].startsWith("exec:am broadcast -a io.github.anmirror.phone.ADB_PROOF "), opened[0])
        assertEquals(1, closes, "the exec stream is closed")
        // Each nonce completes once: a replay finds nothing.
        assertFalse(proof.deliver(nonceOf(opened[0])))
    }

    @Test
    fun execAnsweredWithoutTheBroadcastTimesOutAtThreeSeconds() = runTest {
        val result = async { proof.prove { service -> opened += service; pipe() } }
        advanceTimeBy(AdbPeerProof.TIMEOUT_MS - 1)
        runCurrent()
        assertFalse(result.isCompleted, "not before 3 s")
        advanceTimeBy(1)
        runCurrent()
        assertFalse(result.await())
        assertEquals(AdbPeerProof.TIMEOUT_MS, currentTime)
        assertEquals(1, closes)
        // A broadcast arriving after the timeout proves nothing.
        assertFalse(proof.deliver(nonceOf(opened[0])))
    }

    @Test
    fun anotherNonceDoesNotProve() = runTest {
        val result = async {
            proof.prove { _ ->
                assertFalse(proof.deliver(proof.newNonce()))
                pipe()
            }
        }
        advanceTimeBy(AdbPeerProof.TIMEOUT_MS + 1)
        assertFalse(result.await())
    }

    @Test
    fun malformedNoncesAreIgnored() {
        for (bad in listOf(null, "", "0123", "Z".repeat(32), "0".repeat(31), "0".repeat(33), "0".repeat(32) + "\n")) {
            assertFalse(proof.deliver(bad), "$bad")
        }
    }

    @Test
    fun failedOpenDoesNotProve() = runTest {
        assertFalse(proof.prove { _ -> throw IOException("CLSE") })
        assertEquals(0, closes)
    }

    @Test
    fun openThatHangsIsBoundedToo() = runTest {
        val never = CompletableDeferred<AdbPipe>()
        val result = async { proof.prove { _ -> never.await() } }
        advanceTimeBy(AdbPeerProof.TIMEOUT_MS + 1)
        assertFalse(result.await())
    }
}
