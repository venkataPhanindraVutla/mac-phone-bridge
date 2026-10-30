package io.github.anmirror.phone

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PairingFailure
import io.github.anmirror.connection.PhoneConnectionState
import io.github.anmirror.feature.mirror.PairingError
import io.github.anmirror.feature.mirror.SetupState
import io.github.anmirror.feature.proximity.AdvertiserState
import io.github.anmirror.protocol.v1.AvailabilityReason
import io.github.anmirror.protocol.v1.DndAvailability
import io.github.anmirror.protocol.v1.FeatureAvailability

/** What the pairing screen says for each way pairing can fail. */
fun PairingFailure.messageRes(): Int = when (this) {
    PairingFailure.UNREACHABLE -> R.string.pair_failure_unreachable
    PairingFailure.EXPIRED -> R.string.pair_failure_expired
    PairingFailure.BAD_SECRET -> R.string.pair_failure_bad_secret
    PairingFailure.REJECTED -> R.string.pair_failure_rejected
    PairingFailure.TIMED_OUT -> R.string.pair_failure_timed_out
    PairingFailure.PROTOCOL_MISMATCH -> R.string.pair_failure_protocol_mismatch
}

/**
 * What Home and the notification say for a connection state. [R.string.state_connected] and
 * [R.string.state_looking] take the Mac's name as their one argument.
 */
fun PhoneConnectionState.messageRes(): Int = when (this) {
    is PhoneConnectionState.Connected -> R.string.state_connected
    is PhoneConnectionState.Connecting, PhoneConnectionState.Searching -> R.string.state_looking
    is PhoneConnectionState.Unreachable -> PairingFailure.UNREACHABLE.messageRes()
    is PhoneConnectionState.NotRecognized -> R.string.state_not_recognized
    is PhoneConnectionState.Busy -> R.string.state_busy
    is PhoneConnectionState.Incompatible -> R.string.state_incompatible
    PhoneConnectionState.Stopped, PhoneConnectionState.NotPaired -> R.string.state_stopped
}

/** True if [messageRes]'s string takes the Mac's name. */
fun PhoneConnectionState.copyNamesMac(): Boolean =
    this is PhoneConnectionState.Connected || this is PhoneConnectionState.Connecting || this == PhoneConnectionState.Searching

/** The Mac a state is about, if any. */
val PhoneConnectionState.macOrNull: PairedMac?
    get() = when (this) {
        is PhoneConnectionState.Connected -> mac
        is PhoneConnectionState.Connecting -> mac
        is PhoneConnectionState.Unreachable -> mac
        is PhoneConnectionState.NotRecognized -> mac
        is PhoneConnectionState.Incompatible -> mac
        is PhoneConnectionState.Busy -> mac
        PhoneConnectionState.NotPaired, PhoneConnectionState.Searching, PhoneConnectionState.Stopped -> null
    }

/**
 * What the Forget dialog says. Only a connected Mac hears `system.goodbye UNPAIRED` and forgets
 * this phone too; otherwise the Mac keeps listing it until removed there.
 */
fun PhoneConnectionState.forgetBodyRes(): Int =
    if (this is PhoneConnectionState.Connected) R.string.home_forget_body_connected else R.string.home_forget_body_not_connected

/**
 * The direction lines of "Sync Do Not Disturb with your Mac", given the switch, Do Not Disturb
 * access and the Mac's last `dnd.availability` (null: none yet, or not connected). Phone to Mac
 * follows the Mac's `applies`, Mac to phone its `sends` and this phone's access (without access the
 * row shows the Allow button instead). A Mac reason without copy shows no line; the same line is
 * never shown twice.
 */
fun dndRowLines(on: Boolean, access: Boolean, mac: DndAvailability?): List<Int> {
    if (!on || mac == null) return emptyList()
    val phoneToMac = when {
        mac.applies.enabled -> R.string.home_dnd_phone_to_mac
        else -> mac.applies.macReasonLine()
    }
    val macToPhone = when {
        !mac.sends.enabled -> mac.sends.macReasonLine()
        access -> R.string.home_dnd_mac_to_phone
        else -> null
    }
    return listOfNotNull(phoneToMac, macToPhone).distinct()
}

/**
 * Why the Mac doesn't do its part: shortcuts missing (applying), Focus status not allowed or not
 * readable in that build (sending), or its setting off (either).
 */
private fun FeatureAvailability.macReasonLine(): Int? = when (reason) {
    AvailabilityReason.AVAILABILITY_REASON_NEEDS_SETUP -> R.string.home_dnd_needs_shortcuts
    AvailabilityReason.AVAILABILITY_REASON_OFF_BY_USER -> R.string.home_dnd_mac_off
    AvailabilityReason.AVAILABILITY_REASON_NEEDS_PERMISSION -> R.string.home_dnd_mac_needs_focus_access
    AvailabilityReason.AVAILABILITY_REASON_UNAVAILABLE -> R.string.home_dnd_mac_cant_read_focus
    else -> null
}

/**
 * The note under "Let your Mac lock when you walk away" while it is on: the Nearby devices
 * permission first (the row adds its Allow button), then Bluetooth off, then a phone that can't
 * advertise. Null when it works, or is off.
 */
fun proximityRowLine(on: Boolean, granted: Boolean, adapter: AdvertiserState): Int? = when {
    !on -> null
    !granted -> R.string.home_proximity_needs_permission
    adapter == AdvertiserState.BLUETOOTH_OFF -> R.string.home_proximity_bluetooth_off
    adapter == AdvertiserState.UNSUPPORTED -> R.string.home_proximity_unsupported
    else -> null
}

/**
 * Why the trackpad can't be used, for Home's "Use as trackpad" and the trackpad screen: not
 * connected, or the Mac's pointer control is off or lacks Accessibility. Null when it can be used,
 * when this Mac has no trackpad support (Home hides the row), or before the Mac has said.
 */
fun trackpadLine(state: PhoneConnectionState, mac: MacInputAvailability?): Int? = when {
    state !is PhoneConnectionState.Connected -> R.string.clipboard_not_connected
    !inputShared(state) || mac == null || mac.session !== state || mac.availability.enabled -> null
    mac.availability.reason == AvailabilityReason.AVAILABILITY_REASON_NEEDS_PERMISSION -> R.string.trackpad_mac_needs_accessibility
    else -> R.string.trackpad_mac_off
}

/** What the Full mode screen and the pairing notification say for each way pairing can fail. */
fun pairingErrorRes(error: PairingError): Int = when (error) {
    PairingError.WRONG_PORT -> R.string.full_error_wrong_port
    PairingError.WRONG_CODE -> R.string.full_error_wrong_code
    PairingError.NOT_LISTENING -> R.string.full_error_not_listening
    PairingError.INVALID -> R.string.full_error_invalid
    PairingError.TIMEOUT -> R.string.full_error_timeout
}

/** The Full mode screen's status line for a setup state; null when it has none. */
fun SetupState.statusRes(): Int? = when (this) {
    SetupState.Looking -> R.string.full_status_looking
    is SetupState.Pairing -> R.string.full_status_pairing
    SetupState.Connecting -> R.string.full_status_connecting
    SetupState.Ready -> R.string.full_status_ready
    SetupState.Unpaired, is SetupState.PairFailed, SetupState.ConnectFailed -> null
}

/** The home row's line for [MirrorRowLine]. */
fun MirrorRowLine.messageRes(): Int = when (this) {
    MirrorRowLine.NEEDS_ANDROID_11 -> R.string.home_mirror_needs_android_11
    MirrorRowLine.NEEDS_SETUP -> R.string.home_mirror_needs_setup
    MirrorRowLine.WIRELESS_DEBUGGING_OFF -> R.string.home_mirror_wireless_debugging_off
    MirrorRowLine.READY -> R.string.home_mirror_ready
}
