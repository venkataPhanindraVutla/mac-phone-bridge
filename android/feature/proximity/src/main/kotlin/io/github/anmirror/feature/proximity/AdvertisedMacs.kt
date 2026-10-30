package io.github.anmirror.feature.proximity

import io.github.anmirror.connection.PairedMac

/** The Macs the phone advertises for (F-15, ruling R31): each paired Mac, up to [MAX]. */
object AdvertisedMacs {
    /** At most this many advertising sets: controllers have few slots. */
    const val MAX = 3

    /**
     * In priority order: the connected Mac first, then the others by most recent connection. A
     * phone connected to one Mac must not look away to another it was near.
     */
    fun pick(macs: List<PairedMac>, connected: PairedMac?): List<PairedMac> {
        val others = macs.filter { it.id != connected?.id }.sortedByDescending { it.lastConnectedAt }
        return (listOfNotNull(connected) + others).take(MAX)
    }
}
