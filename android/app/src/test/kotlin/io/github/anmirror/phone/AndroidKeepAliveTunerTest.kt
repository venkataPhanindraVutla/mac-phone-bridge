package io.github.anmirror.phone

import io.github.anmirror.phone.platform.AndroidKeepAliveTuner
import java.io.IOException
import java.net.Socket
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AndroidKeepAliveTunerTest {
    @Test
    fun setsKeepAliveThenIdleIntervalCount() {
        val set = ArrayList<Pair<Int, Int>>()
        val fallbacks = ArrayList<String>()
        Socket().use { socket ->
            AndroidKeepAliveTuner(setTcpOption = { s, option, value ->
                assertTrue(s.keepAlive, "keepalive is on before the timings")
                set += option to value
            }, onFallback = { fallbacks += it }).tune(socket)
            assertTrue(socket.keepAlive)
        }
        // Linux TCP_KEEPIDLE = 4, TCP_KEEPINTVL = 5, TCP_KEEPCNT = 6; SPEC 7 timings.
        assertEquals(listOf(4 to 60, 5 to 10, 6 to 3), set)
        assertEquals(emptyList(), fallbacks)
    }

    @Test
    fun failedTimingsKeepBasicKeepAliveAndRecordOnce() {
        val fallbacks = ArrayList<String>()
        val tuner = AndroidKeepAliveTuner(
            setTcpOption = { _, _, _ -> throw IOException("detail that must not be logged") },
            onFallback = { fallbacks += it },
        )
        Socket().use { socket ->
            tuner.tune(socket)
            assertTrue(socket.keepAlive)
        }
        Socket().use { tuner.tune(it) }
        assertEquals(listOf("basic,IOException"), fallbacks)
    }
}
