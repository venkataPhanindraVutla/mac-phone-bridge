package io.github.anmirror.transfer

import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferKind

enum class Direction { SEND, RECEIVE }

/**
 * [PAUSED] (files.resume.v1): a send that broke and will be offered again; a receive that broke
 * and keeps its bytes for the Mac's next offer.
 */
enum class TransferState { QUEUED, WAITING, ACTIVE, PAUSED, DONE, FAILED, CANCELLED }

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
    /** A paused send's first retry while connected; each next waits twice as long, up to [maxRetryMs]. */
    val firstRetryMs: Long = 5_000,
    val maxRetryMs: Long = 60_000,
    /** How long a paused send is retried, and a kept receive waits for its offer. */
    val keepPausedMs: Long = 24L * 3600 * 1000,
)
