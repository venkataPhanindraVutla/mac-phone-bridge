package com.genymobile.scrcpy.anmirror;

import org.junit.Assert;
import org.junit.Test;

public class HotspotTest {

    @Test
    public void okLineIsHexAndSecurityName() {
        Assert.assertEquals("ok 5069 78656c2037 wpa2", Hotspot.okLine("Pi", "xel 7", 1));
        Assert.assertEquals("ok 41 - open", Hotspot.okLine("A", null, 0));
        Assert.assertEquals("ok c3a9 - open", Hotspot.okLine("é", "", 5));
    }

    @Test
    public void securityTypes() {
        Assert.assertEquals("wpa3_transition", Hotspot.securityName(2));
        Assert.assertEquals("wpa3", Hotspot.securityName(3));
        Assert.assertEquals("open", Hotspot.securityName(4));
    }
}
