package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.AvailabilityReason
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
