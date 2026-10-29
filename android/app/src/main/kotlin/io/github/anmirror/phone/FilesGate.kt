package io.github.anmirror.phone

import io.github.anmirror.protocol.v1.TransferError

/** The features whose transfers travel as `files.*` over bulk connections (SPEC 13, 16). */
val BULK_CAPABILITIES = setOf("files.v1", "browse.v1", "screenshots.v1", "photos.v1")

/** `files.*` messages may flow while the Mac shares any feature they carry. */
fun bulkShared(shared: Set<String>): Boolean = BULK_CAPABILITIES.any { it in shared }

/**
 * R5: whether the phone takes a Mac `files.offer`. A plain offer is a file for Downloads and
 * needs files.v1; one with a browse target is a browse write and needs browse.v1. Null to take
 * it, else the reason for `files.reject`.
 */
fun offerRefusal(hasTarget: Boolean, shared: Set<String>): TransferError? {
    val needed = if (hasTarget) "browse.v1" else "files.v1"
    return if (needed in shared) null else TransferError.TRANSFER_ERROR_DISABLED
}
