package io.github.anmirror.feature.mirror

import io.github.anmirror.protocol.v1.HotspotFailure
import io.github.anmirror.protocol.v1.HotspotSecurity
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HotspotRunnerTest {
    @Test fun okLineCarriesTheHotspot() {
        // The Java side's okLine("Pi", "xel 7", 1), after some app_process noise.
        val s = HotspotRunner.parseHotspotLine("WARNING: linker noise\nok 5069 78656c2037 wpa2\n", on = true)
        assertTrue(s.on)
        assertEquals("Pi", s.ssid)
        assertEquals("xel 7", s.passphrase)
        assertEquals(HotspotSecurity.HOTSPOT_SECURITY_WPA2, s.security)
        val open = HotspotRunner.parseHotspotLine("ok c3a9 - open", on = true)
        assertEquals("é", open.ssid)
        assertEquals("", open.passphrase)
        assertEquals(HotspotSecurity.HOTSPOT_SECURITY_OPEN, open.security)
    }

    @Test fun failuresAndOff() {
        assertEquals(HotspotFailure.HOTSPOT_FAILURE_REFUSED, HotspotRunner.parseHotspotLine("fail refused tether-error-3", true).failure)
        assertEquals(HotspotFailure.HOTSPOT_FAILURE_FAILED, HotspotRunner.parseHotspotLine("fail failed timeout", true).failure)
        assertEquals(HotspotFailure.HOTSPOT_FAILURE_FAILED, HotspotRunner.parseHotspotLine("Exception in thread main", true).failure)
        assertEquals(HotspotFailure.HOTSPOT_FAILURE_FAILED, HotspotRunner.parseHotspotLine("ok zz 00 wpa2", true).failure)
        val off = HotspotRunner.parseHotspotLine("off", on = false)
        assertFalse(off.on)
        assertEquals(HotspotFailure.HOTSPOT_FAILURE_UNSPECIFIED, off.failure)
    }

    @Test fun commandRunsTheEntryPointFromTheJar() {
        assertEquals(
            "CLASSPATH=/data/local/tmp/anmirror-helper-0000002a.jar app_process / com.genymobile.scrcpy.anmirror.Hotspot on",
            HotspotRunner.command(ServerCommand.jarPath(42), on = true),
        )
    }
}
