package com.genymobile.scrcpy.anmirror;

import org.junit.Assert;
import org.junit.Test;

public class PeerCheckTest {

    @Test
    public void shellAndRootAreAllowed() {
        Assert.assertTrue(PeerCheck.isAllowed(2000));
        Assert.assertTrue(PeerCheck.isAllowed(0));
    }

    @Test
    public void appsAreRefused() {
        Assert.assertFalse(PeerCheck.isAllowed(10123));
        Assert.assertFalse(PeerCheck.isAllowed(1000));
        Assert.assertFalse(PeerCheck.isAllowed(1));
    }
}
