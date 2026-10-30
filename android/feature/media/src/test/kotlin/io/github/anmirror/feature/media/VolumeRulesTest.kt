package io.github.anmirror.feature.media

import android.media.VolumeProvider
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VolumeRulesTest {
    @Test fun onlyAbsoluteRemoteVolumeCanBeSet() {
        assertFalse(VolumeRules.remoteFixed(VolumeProvider.VOLUME_CONTROL_ABSOLUTE))
        assertTrue(VolumeRules.remoteFixed(VolumeProvider.VOLUME_CONTROL_RELATIVE))
        assertTrue(VolumeRules.remoteFixed(VolumeProvider.VOLUME_CONTROL_FIXED))
    }

    @Test fun onlyVolumeSettingsAreWatched() {
        assertTrue(VolumeRules.isVolumeSetting("volume_music_speaker"))
        assertTrue(VolumeRules.isVolumeSetting("volume_music"))
        // No name, or the whole table: it may be the volume, look again.
        assertTrue(VolumeRules.isVolumeSetting(null))
        assertTrue(VolumeRules.isVolumeSetting("system"))
        assertFalse(VolumeRules.isVolumeSetting("screen_brightness"))
    }
}
