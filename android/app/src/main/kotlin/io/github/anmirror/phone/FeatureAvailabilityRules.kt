package io.github.anmirror.phone

import io.github.anmirror.feature.proximity.AdvertiserState
import io.github.anmirror.protocol.v1.AvailabilityReason
import io.github.anmirror.protocol.v1.DndAvailability
import io.github.anmirror.protocol.v1.FeatureAvailability

/**
 * What a phone feature reports to the Mac (`*.availability`). The user's switch comes first: a
 * feature the user has not turned on is "off", and only a turned-on feature that lacks its
 * system permission "needs permission".
 */
fun featureAvailability(granted: Boolean, userOn: Boolean): FeatureAvailability {
    val builder = FeatureAvailability.newBuilder()
    when {
        !userOn -> builder.setEnabled(false).setReason(AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER)
        !granted -> builder.setEnabled(false).setReason(AvailabilityReason.AVAILABILITY_REASON_NEEDS_PERMISSION)
        else -> builder.setEnabled(true)
    }
    return builder.build()
}

/**
 * The phone's `dnd.availability` (SPEC 21): it sends its transitions whenever the switch is on
 * (reading the filter needs no permission), and applies the Mac's only with Do Not Disturb access.
 */
fun dndAvailability(userOn: Boolean, policyAccess: Boolean): DndAvailability = DndAvailability.newBuilder()
    .setSends(featureAvailability(granted = true, userOn = userOn))
    .setApplies(featureAvailability(granted = policyAccess, userOn = userOn))
    .build()

/**
 * The phone's `proximity.availability` (SPEC 22): whether it advertises. The switch comes first,
 * then BLUETOOTH_ADVERTISE (API 31+), then an adapter that is off or can't advertise (UNAVAILABLE).
 */
fun proximityAvailability(userOn: Boolean, granted: Boolean, adapter: AdvertiserState): FeatureAvailability = when {
    !userOn || !granted || adapter == AdvertiserState.READY -> featureAvailability(granted = granted, userOn = userOn)
    else -> FeatureAvailability.newBuilder()
        .setEnabled(false)
        .setReason(AvailabilityReason.AVAILABILITY_REASON_UNAVAILABLE)
        .build()
}

/** How much of the phone's photos and videos this app may read. */
enum class MediaAccess {
    /** All of them: READ_MEDIA_IMAGES (API 33+) or READ_EXTERNAL_STORAGE (up to 32). */
    FULL,

    /** Only the ones the user picked: READ_MEDIA_VISUAL_USER_SELECTED alone (API 34+). */
    PARTIAL,
    NONE,
}

/**
 * [featureAvailability] for a feature that reads photos. With [MediaAccess.PARTIAL], a feature
 * for which the picked photos still work ([partialWorks], photos) is enabled and says so
 * (`PARTIAL_ACCESS`); one that needs them all (screenshots: new ones can't be found) is not.
 */
fun mediaFeatureAvailability(access: MediaAccess, userOn: Boolean, partialWorks: Boolean): FeatureAvailability {
    if (!userOn || access != MediaAccess.PARTIAL) return featureAvailability(granted = access == MediaAccess.FULL, userOn = userOn)
    return FeatureAvailability.newBuilder()
        .setEnabled(partialWorks)
        .setReason(AvailabilityReason.AVAILABILITY_REASON_PARTIAL_ACCESS)
        .build()
}
