package io.github.anmirror.feature.proximity

import io.github.anmirror.connection.PairedMac

/** The one Mac the phone advertises for (F-15). */
object AdvertisedMac {
    /** The connected Mac, else the paired one connected to most recently; null when none is paired. */
    fun pick(macs: List<PairedMac>, connected: PairedMac?): PairedMac? =
        connected ?: macs.maxByOrNull { it.lastConnectedAt }
}
