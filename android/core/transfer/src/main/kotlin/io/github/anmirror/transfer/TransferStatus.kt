package io.github.anmirror.transfer

import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferKind

enum class Direction { SEND, RECEIVE }

enum class TransferState { QUEUED, WAITING, ACTIVE, DONE, FAILED, CANCELLED }

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
)

data class TransferTiming(
    val acceptTimeoutMs: Long = 30_000,
    val stallTimeoutMs: Long = 30_000,
    val progressIntervalMs: Long = 500,
    val freeMarginBytes: Long = 64L shl 20,
)
