package io.github.anmirror.transfer

import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferKind

enum class Direction { SEND, RECEIVE }

enum class TransferState { QUEUED, WAITING, ACTIVE, DONE, FAILED, CANCELLED }

/**
 * One transfer as the engine sees it. [requestId] is the Mac request a send answers (photos.fetch,
 * browse.read), else 0; [browseTarget] is true for a receive whose offer had a browse `target`.
 */
data class TransferStatus(
    val id: String,
    val direction: Direction,
    val name: String,
    val size: Long,
    val done: Long,
    val kind: TransferKind,
    val state: TransferState,
    val error: TransferError? = null,
    val savedAs: String? = null,
    val requestId: Long = 0,
    val browseTarget: Boolean = false,
)

data class TransferTiming(
    val acceptTimeoutMs: Long = 30_000,
    val stallTimeoutMs: Long = 30_000,
    val progressIntervalMs: Long = 500,
    val freeMarginBytes: Long = 64L shl 20,
)
