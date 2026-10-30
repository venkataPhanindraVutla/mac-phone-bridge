package io.github.anmirror.feature.media

import android.media.VolumeProvider

/** Pure volume rules for [AndroidMediaSessions]. */
internal object VolumeRules {
    /**
     * A remote session's volume can be set to a level only with absolute control. Relative
     * control (up/down steps only) is reported as fixed, so the Mac offers no volume slider.
     */
    fun remoteFixed(volumeControl: Int): Boolean = volumeControl != VolumeProvider.VOLUME_CONTROL_ABSOLUTE

    /**
     * Whether a change to the Settings.System entry [name] can be the local volume: its
     * `volume_*` keys, or (no name, or the table itself) anything.
     */
    fun isVolumeSetting(name: String?): Boolean = name == null || name == "system" || name.startsWith("volume_")
}
