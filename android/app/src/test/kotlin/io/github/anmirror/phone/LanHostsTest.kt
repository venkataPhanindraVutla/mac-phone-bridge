package io.github.anmirror.phone

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LanHostsTest {
    private val allowed = listOf(
        "10.0.0.1", "10.255.255.255",
        "172.16.0.1", "172.31.255.255",
        "192.168.0.121", "192.168.255.1",
        "169.254.10.20",
        "fe80::1", "FE80::1c2d:3e4f", "fe80::1%wlan0", "[fe80::1]", "febf::1",
        "fc00::1", "fd12:3456::1",
        "Phanis-MacBook-Air.local", "mac.LOCAL", "mac.local.", "a.b.local",
    )

    private val denied = listOf(
        "8.8.8.8", "1.1.1.1", "172.15.255.255", "172.32.0.1", "192.169.0.1", "11.0.0.1",
        "127.0.0.1", "0.0.0.0", "255.255.255.255", "169.253.1.1",
        "2001:db8::1", "::1", "::", "fec0::1", "fe00::1", "fe80:1", "fe80::zz",
        "example.com", "localhost", "local", ".local", "evil.local.example.com", "my host.local", "-x.local",
        "192.168.1", "192.168.1.256", "192.168.01.1", "1e2.1.1.1", "", " ",
    )

    @Test
    fun lanAddressesAndLocalNamesAreAllowed() {
        allowed.forEach { assertTrue(LanHosts.isLan(it), "should allow $it") }
    }

    @Test
    fun everythingElseIsDropped() {
        denied.forEach { assertFalse(LanHosts.isLan(it), "should drop $it") }
    }

    @Test
    fun filterKeepsOrderAndDropsTheRest() {
        assertEquals(
            listOf("192.168.0.121", "Phanis-MacBook-Air.local"),
            LanHosts.filter(listOf("8.8.8.8", "192.168.0.121", "evil.example", "Phanis-MacBook-Air.local")),
        )
        assertEquals(emptyList(), LanHosts.filter(listOf("8.8.8.8", "example.com")))
    }
}
