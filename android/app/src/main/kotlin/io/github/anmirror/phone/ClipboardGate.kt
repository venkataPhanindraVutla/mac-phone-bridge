package io.github.anmirror.phone

import io.github.anmirror.connection.PhoneConnectionState

/** Whether the phone may send its clipboard now, and if not, why (tile state and toast). */
enum class ClipboardGate { OPEN, OFF, NOT_CONNECTED }

/**
 * Open while connected to a Mac that shares clipboard.v1 with "Share clipboard with your Mac" on.
 * Connected with the switch off is [ClipboardGate.OFF] whatever the Mac shares; anything else is
 * [ClipboardGate.NOT_CONNECTED].
 */
fun clipboardGate(state: PhoneConnectionState, on: Boolean): ClipboardGate = when {
    state !is PhoneConnectionState.Connected -> ClipboardGate.NOT_CONNECTED
    !on -> ClipboardGate.OFF
    "clipboard.v1" !in state.shared -> ClipboardGate.NOT_CONNECTED
    else -> ClipboardGate.OPEN
}

/**
 * Whether the bridge's "the Mac has this text" digest stays valid. Mac text is taken only while the
 * Mac shares clipboard.v1 and the switch is on; otherwise it is dropped, so the digest goes stale
 * and must be cleared.
 */
fun clipboardTracksMac(shared: Boolean, on: Boolean): Boolean = shared && on
