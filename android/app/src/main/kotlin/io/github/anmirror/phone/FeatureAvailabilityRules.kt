package io.github.anmirror.phone

import io.github.anmirror.connection.PhoneConnectionState
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
 * Which `dnd.availability` to send a session, and when. A new session re-reads the Do Not Disturb
 * access first ([readAccess]; it may have been granted while no session was up, with no broadcast
 * seen) and always gets one; later in the same session one goes out only when it changed.
 */
class DndAvailabilityOnSession(private val readAccess: () -> Boolean) {
    private var session: Any? = null
    private var last: DndAvailability? = null

    /** The availability to send [session] now, or null when it has it already. */
    fun next(session: Any, userOn: Boolean, access: Boolean): DndAvailability? {
        val policyAccess = if (session !== this.session) {
            this.session = session
            last = null
            readAccess()
        } else {
            access
        }
        val a = dndAvailability(userOn = userOn, policyAccess = policyAccess)
        if (a == last) return null
        last = a
        return a
    }
}

/**
 * The phone's `proximity.availability` for one Mac (SPEC 22): whether the phone advertises for it.
 * The switch comes first, then BLUETOOTH_ADVERTISE (API 31+); then an adapter that is off or can't
 * advertise, or this Mac's advertisement [faulted] (it failed, or the system stopped it, and has not
 * started since: ruling R30), is UNAVAILABLE.
 */
fun proximityAvailability(userOn: Boolean, granted: Boolean, adapter: AdvertiserState, faulted: Boolean): FeatureAvailability = when {
    !userOn || !granted || (adapter == AdvertiserState.READY && !faulted) -> featureAvailability(granted = granted, userOn = userOn)
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

/** The Mac's last `input.availability` (SPEC 23), and the session it came in. */
class MacInputAvailability(val session: PhoneConnectionState.Connected, val availability: FeatureAvailability)

/** The Mac shares input.v1 in [state]. */
fun inputShared(state: PhoneConnectionState): Boolean = state is PhoneConnectionState.Connected && "input.v1" in state.shared

/**
 * The trackpad may send: connected, the Mac shares input.v1, and its last `input.availability`
 * in this very session is enabled. Nothing heard yet, or heard in an earlier session, is closed.
 */
fun inputOpen(state: PhoneConnectionState, mac: MacInputAvailability?): Boolean =
    inputShared(state) && mac != null && mac.session === state && mac.availability.enabled

/** Full mode needs Android 11: Wireless debugging and its pairing came with API 30. */
const val MIRROR_MIN_SDK = 30

/**
 * The phone's `mirror.availability` (SPEC 24). Android 10 can never mirror; then the switch; then
 * the setup: not paired, Wireless debugging off, or the last connect to it failed. An unreadable
 * Wireless debugging setting ([wirelessDebugging] null) never blocks.
 */
fun mirrorAvailability(
    sdk: Int,
    userOn: Boolean,
    paired: Boolean,
    wirelessDebugging: Boolean?,
    lastConnectFailed: Boolean,
): FeatureAvailability {
    val reason = when {
        sdk < MIRROR_MIN_SDK -> AvailabilityReason.AVAILABILITY_REASON_UNAVAILABLE
        !userOn -> AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER
        !paired || wirelessDebugging == false || lastConnectFailed -> AvailabilityReason.AVAILABILITY_REASON_NEEDS_SETUP
        else -> return FeatureAvailability.newBuilder().setEnabled(true).build()
    }
    return FeatureAvailability.newBuilder().setEnabled(false).setReason(reason).build()
}

/** The line under "Allow your Mac to show this screen" (the running line comes with the session). */
enum class MirrorRowLine { NEEDS_ANDROID_11, NEEDS_SETUP, WIRELESS_DEBUGGING_OFF, READY }

/** Which [MirrorRowLine] the home row shows; none while the switch is off on a phone that can mirror. */
fun mirrorRowLine(sdk: Int, on: Boolean, paired: Boolean, wirelessDebugging: Boolean?, lastConnectFailed: Boolean): MirrorRowLine? = when {
    sdk < MIRROR_MIN_SDK -> MirrorRowLine.NEEDS_ANDROID_11
    !on -> null
    !paired -> MirrorRowLine.NEEDS_SETUP
    wirelessDebugging == false || lastConnectFailed -> MirrorRowLine.WIRELESS_DEBUGGING_OFF
    else -> MirrorRowLine.READY
}
