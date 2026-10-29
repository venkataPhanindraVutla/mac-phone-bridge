package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.transfer.TransferState
import io.github.anmirror.transfer.TransferStatus

/** The features whose transfers travel as `files.*` over bulk connections (SPEC 13, 16). */
val BULK_CAPABILITIES = setOf("files.v1", "browse.v1", "screenshots.v1", "photos.v1")

/** `files.*` messages may flow while the Mac shares any feature they carry. */
fun bulkShared(shared: Set<String>): Boolean = BULK_CAPABILITIES.any { it in shared }

/**
 * R5: whether the phone takes a Mac `files.offer`. A plain offer is a file for Downloads and
 * needs files.v1; one with a browse target is a browse write and needs browse open ([browseOpen]:
 * the Mac shares browse.v1, the switch is on, there is a root). Null to take it, else the reason
 * for `files.reject`.
 */
fun offerRefusal(hasTarget: Boolean, shared: Set<String>, browseOpen: Boolean): TransferError? {
    val allowed = if (hasTarget) "browse.v1" in shared && browseOpen else "files.v1" in shared
    return if (allowed) null else TransferError.TRANSFER_ERROR_DISABLED
}

/**
 * R5 for the phone's own offers, on top of [bulkShared]: a screenshot goes only while its
 * feature is open (the Mac shares screenshots.v1, the switch is on, all photos are readable), a
 * photo only while photos is (photos.v1, the switch, some photos readable), and a file answering a
 * browse.read ([requestId] set) only while browse is; any other bulk capability is not enough. A
 * file the user shared (no request) needs nothing more.
 */
fun phoneOfferAllowed(
    kind: TransferKind,
    requestId: Long,
    screenshotsOpen: Boolean,
    photosOpen: Boolean,
    browseOpen: Boolean,
): Boolean = when (kind) {
    TransferKind.TRANSFER_KIND_SCREENSHOT -> screenshotsOpen
    TransferKind.TRANSFER_KIND_PHOTO -> photosOpen
    else -> requestId == 0L || browseOpen
}

/**
 * Which tracked shared files can be closed: those whose transfer ended, or dropped off the
 * engine's recent list (only finished transfers do). [fresh] must be read after [tracked] was
 * taken, so every tracked ID was already registered with the engine and a just-queued file is
 * listed as live.
 */
fun sharesToRelease(tracked: Collection<String>, fresh: List<TransferStatus>): List<String> {
    val live = fresh.filter { it.state.isOngoing() }.mapTo(HashSet()) { it.id }
    return tracked.filter { it !in live }
}

/** Queued, waiting for the peer, or moving bytes. */
fun TransferState.isOngoing(): Boolean =
    this == TransferState.QUEUED || this == TransferState.WAITING || this == TransferState.ACTIVE
