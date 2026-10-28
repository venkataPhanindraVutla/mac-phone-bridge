package io.github.anmirror.phone

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PairingFailure
import io.github.anmirror.connection.PhoneConnectionState

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
