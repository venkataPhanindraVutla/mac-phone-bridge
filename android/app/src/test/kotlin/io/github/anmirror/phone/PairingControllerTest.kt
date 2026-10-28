package io.github.anmirror.phone

import io.github.anmirror.connection.ConnectionManager
import io.github.anmirror.connection.ControlChannel
import io.github.anmirror.connection.InMemoryPairedMacStore
import io.github.anmirror.connection.MacConnector
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PairingFailure
import io.github.anmirror.connection.PairingResult
import io.github.anmirror.connection.PhonePairingClient
import io.github.anmirror.connection.StaticDiscovery
import io.github.anmirror.connection.TlsIdentity
import io.github.anmirror.connection.UnreachableException
import io.github.anmirror.protocol.PairingUri
import io.github.anmirror.protocol.v1.Hello
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.util.concurrent.CopyOnWriteArrayList
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class PairingControllerTest {
    private val macFp = ByteArray(32) { 7 }
    private val macFpHex = macFp.joinToString("") { "%02x".format(it) }

    private fun link(hosts: List<String>, name: String = "Studio") =
        PairingUri(macFingerprint = macFp, secret = ByteArray(32) { 3 }, hosts = hosts, port = 4000, macName = name).toUriString()

    private class Rig(
        val controller: PairingController,
        val dials: MutableList<List<String>>,
        val starts: () -> Int,
        val store: InMemoryPairedMacStore,
        val manager: ConnectionManager,
    )

    /** [hang]: the connector never returns (a pairing stays in progress). */
    private fun TestScope.rig(
        paired: List<PairedMac> = emptyList(),
        hang: Boolean = false,
        pairer: (suspend (PairingUri, suspend (String) -> Boolean) -> PairingResult)? = null,
    ): Rig {
        val dials = CopyOnWriteArrayList<List<String>>()
        val connector = MacConnector { hosts, _, _ ->
            dials += hosts
            if (hang) CompletableDeferred<Unit>().await()
            throw UnreachableException(hosts)
        }
        val identity = object : TlsIdentity {
            override val certificateDer = ByteArray(0)
            override fun keyManagers(): Array<KeyManager> = emptyArray()
        }
        val store = InMemoryPairedMacStore(paired)
        val manager = ConnectionManager(backgroundScope, store, StaticDiscovery(emptyList()), connector, { Hello.getDefaultInstance() })
        var starts = 0
        val controller = PairingController(
            scope = backgroundScope,
            pair = pairer ?: PhonePairingClient(connector, identity, "Phone", "Model")::pair,
            store = store,
            manager = manager,
            startService = { starts++ },
        )
        return Rig(controller, dials, { starts }, store, manager)
    }

    @Test
    fun linkWaitsForConsentBeforeDialing() = runTest {
        val r = rig()
        r.controller.offerLink(link(listOf("192.168.0.121")))
        runCurrent()
        val offer = assertIs<PairingState.LinkOffer>(r.controller.state.value)
        assertEquals("Studio", offer.macName)
        assertNull(offer.switchesFrom)
        assertEquals(emptyList(), r.dials, "nothing is dialed before Continue")
        r.controller.acceptLink()
        runCurrent()
        assertEquals(listOf(listOf("192.168.0.121")), r.dials)
        assertEquals(PairingState.Failed(PairingFailure.UNREACHABLE), r.controller.state.value)
    }

    @Test
    fun declinedLinkIsNeverDialed() = runTest {
        val r = rig()
        r.controller.offerLink(link(listOf("192.168.0.121")))
        runCurrent()
        r.controller.cancel()
        runCurrent()
        assertEquals(PairingState.Idle, r.controller.state.value)
        assertEquals(emptyList(), r.dials)
    }

    @Test
    fun linkDoesNotCancelAPairingInProgress() = runTest {
        val r = rig(hang = true)
        r.controller.pair(link(listOf("10.0.0.5"), name = "First"))
        runCurrent()
        assertEquals(PairingState.Connecting("First"), r.controller.state.value)
        r.controller.offerLink(link(listOf("10.0.0.9"), name = "Second"))
        runCurrent()
        assertEquals(PairingState.Connecting("First"), r.controller.state.value, "the link is ignored")
        assertEquals(listOf(listOf("10.0.0.5")), r.dials)
    }

    @Test
    fun linkOfferSaysWhichMacItSwitchesFrom() = runTest {
        val current = PairedMac("aa", "Office iMac", "aa", ByteArray(32), "10.0.0.2", 4000, 5)
        val r = rig(paired = listOf(current))
        r.controller.offerLink(link(listOf("192.168.0.121")))
        runCurrent()
        assertEquals("Office iMac", assertIs<PairingState.LinkOffer>(r.controller.state.value).switchesFrom)
    }

    @Test
    fun repairingTheSameMacSwitchesFromNothing() = runTest {
        val same = PairedMac(macFpHex, "Studio", macFpHex, ByteArray(32), "10.0.0.2", 4000, 5)
        val r = rig(paired = listOf(same))
        r.controller.offerLink(link(listOf("192.168.0.121")))
        runCurrent()
        assertNull(assertIs<PairingState.LinkOffer>(r.controller.state.value).switchesFrom)
    }

    @Test
    fun hostsOffTheLocalNetworkAreNeverDialed() = runTest {
        val r = rig()
        r.controller.pair(link(listOf("8.8.8.8")))
        runCurrent()
        assertEquals(PairingState.Failed(PairingFailure.UNREACHABLE), r.controller.state.value)
        assertEquals(emptyList(), r.dials, "no LAN host: nothing dialed")

        r.controller.dismiss()
        r.controller.pair(link(listOf("8.8.8.8", "192.168.1.20", "evil.example.com", "mac.local")))
        runCurrent()
        assertEquals(listOf(listOf("192.168.1.20", "mac.local")), r.dials, "only LAN hosts are dialed")
    }

    @Test
    fun pairingBWhileAIsPairedKeepsAAndMakesBActive() = runTest {
        // R29: a phone may be paired with several Macs; it connects to one at a time.
        val a = PairedMac("aa".repeat(32), "Office iMac", "aa".repeat(32), ByteArray(32), "10.0.0.2", 4000, 5)
        val b = PairedMac(macFpHex, "Studio", macFpHex, ByteArray(32), "192.168.0.121", 4000, 10)
        // A channel that is already dead: the manager then dials B's address as usual.
        val socket = SSLContext.getDefault().socketFactory.createSocket() as SSLSocket
        val r = rig(paired = listOf(a), pairer = { _, _ -> PairingResult.Paired(b, ControlChannel(socket, "192.168.0.121")) })
        r.controller.pair(link(listOf("192.168.0.121")))
        runCurrent()
        assertEquals(PairingState.Paired("Studio"), r.controller.state.value)
        assertEquals(setOf(a.id, b.id), r.store.all().map { it.id }.toSet(), "A stays paired")
        assertEquals(1, r.starts())
        r.manager.start()
        runCurrent()
        assertEquals(listOf("192.168.0.121"), r.dials.first(), "B is the Mac the manager connects to")
        assertTrue(r.dials.none { it == listOf("10.0.0.2") }, "A is not dialed")
    }

    @Test
    fun confirmWithoutACodeOnScreenDoesNothing() = runTest {
        val r = rig(hang = true)
        r.controller.confirm() // no code shown: nothing to confirm, no service start
        assertEquals(0, r.starts())
        assertTrue(r.dials.isEmpty())
    }
}
