package io.github.anmirror.feature.input

/** One pointer of a Compose pointer event, as far as [isPointerCancel] needs it. */
data class PointerSnapshot(val pressed: Boolean, val previousPressed: Boolean, val consumed: Boolean)

/**
 * Compose's ACTION_CANCEL: a release where every pointer is up and one that was down until now
 * comes already consumed (a real lift does not), so it is not taken for a lift, which could click.
 * A pointer that was up already proves nothing: a cancel right after a lift must not pass for a lift.
 */
fun isPointerCancel(release: Boolean, changes: List<PointerSnapshot>): Boolean =
    release && changes.isNotEmpty() && changes.all { !it.pressed } && changes.any { it.previousPressed && it.consumed }
