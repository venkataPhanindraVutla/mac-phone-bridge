package io.github.anmirror.adb

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.net.InetAddress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A hand-driven NsdManager: the test decides when discovery starts and how each resolve ends. */
private class FakeNsd : NsdApi {
    class Discovery(val type: String, val callbacks: DiscoveryCallbacks) {
        var stops = 0
    }

    val discoveries = mutableListOf<Discovery>()
    val resolves = mutableListOf<Pair<FoundService, (ResolvedService?) -> Unit>>()

    override fun startDiscovery(type: String, callbacks: DiscoveryCallbacks): Any = Discovery(type, callbacks).also { discoveries += it }
    override fun stopDiscovery(token: Any) {
        (token as Discovery).stops++
    }
    override fun resolve(service: FoundService, done: (ResolvedService?) -> Unit) {
        resolves += service to done
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class NsdAdbFinderTest {
    private val nsd = FakeNsd()
    private val own = InetAddress.getByName("192.168.0.20")
    private val other = InetAddress.getByName("192.168.0.99")
    private val finder = NsdAdbFinder(nsd) { setOf(InetAddress.getLoopbackAddress(), own) }

    @Test
    fun findsThePhonesOwnServiceAndStops() = runTest {
        val result = async { finder.find(AdbService.PAIRING, 6_000) }
        runCurrent()
        val d = nsd.discoveries.single()
        assertEquals("_adb-tls-pairing._tcp", d.type)
        d.callbacks.onStarted()
        d.callbacks.onFound(FoundService("adb-other", null))
        d.callbacks.onFound(FoundService("adb-mine", null))
        // One resolve at a time: the second waits for the first.
        assertEquals(1, nsd.resolves.size)
        nsd.resolves[0].second(ResolvedService(listOf(other), 40001)) // another phone on the network
        assertEquals(2, nsd.resolves.size)
        nsd.resolves[1].second(ResolvedService(listOf(own), 37123))
        assertEquals(AdbEndpoint("192.168.0.20", 37123), result.await())
        assertEquals(1, d.stops)
    }

    @Test
    fun failedResolveIsRetriedOnce() = runTest {
        val result = async { finder.find(AdbService.CONNECT, 5_000) }
        runCurrent()
        val d = nsd.discoveries.single()
        assertEquals("_adb-tls-connect._tcp", d.type)
        d.callbacks.onFound(FoundService("adb-mine", null))
        nsd.resolves[0].second(null) // FAILURE_ALREADY_ACTIVE, say
        assertEquals(2, nsd.resolves.size)
        nsd.resolves[1].second(ResolvedService(listOf(own), 41000))
        assertEquals(AdbEndpoint("192.168.0.20", 41000), result.await())
    }

    @Test
    fun secondFailureGivesUpOnThatRecord() = runTest {
        val result = async { finder.find(AdbService.CONNECT, 5_000) }
        runCurrent()
        nsd.discoveries.single().callbacks.onFound(FoundService("adb-mine", null))
        nsd.resolves[0].second(null)
        nsd.resolves[1].second(null)
        assertEquals(2, nsd.resolves.size)
        advanceTimeBy(5_001)
        assertNull(result.await())
        assertEquals(1, nsd.discoveries.single().stops)
    }

    @Test
    fun stoppedBeforeTheDiscoveryStartedIsStillStopped() = runTest {
        val result = async { finder.find(AdbService.PAIRING, 6_000) }
        runCurrent()
        result.cancel() // a quick second "Start pairing", or forget()
        runCurrent()
        val d = nsd.discoveries.single()
        assertEquals(1, d.stops)
        // The platform confirms the start afterwards: nothing more happens, nothing is resolved.
        d.callbacks.onStarted()
        d.callbacks.onFound(FoundService("adb-mine", null))
        assertEquals(1, d.stops)
        assertTrue(nsd.resolves.isEmpty())
    }

    @Test
    fun startFailureAnswersNull() = runTest {
        val result = async { finder.find(AdbService.PAIRING, 6_000) }
        runCurrent()
        nsd.discoveries.single().callbacks.onStartFailed()
        assertNull(result.await())
    }

    @Test
    fun aLostOrInvalidPortIsIgnored() = runTest {
        val result = async { finder.find(AdbService.PAIRING, 6_000) }
        runCurrent()
        nsd.discoveries.single().callbacks.onFound(FoundService("adb-mine", null))
        nsd.resolves[0].second(ResolvedService(listOf(own), -1))
        advanceTimeBy(6_001)
        assertNull(result.await())
    }
}
