package io.github.anmirror.transfer

import io.github.anmirror.connection.BulkStream
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferOffer
import java.io.InputStream
import java.io.OutputStream

/** A file the phone sends. [open] is called once per attempt, off the main thread. */
interface OutgoingFile {
    val name: String
    val size: Long
    val mime: String
    val modifiedMs: Long
    fun open(): InputStream
}

/** Where received bytes go. Exactly one of [commit] or [abort] is called. */
interface IncomingFile {
    val output: OutputStream

    /** Finalizes the file and returns the name it was saved under. */
    fun commit(): String

    /** Discards everything written so far (no partial file may remain). */
    fun abort()
}

sealed interface SinkResult {
    data class Ready(val file: IncomingFile) : SinkResult
    data class Refused(val reason: TransferError) : SinkResult
}

/** Opens the destination for an incoming offer. The offer's name is already sanitized. */
fun interface IncomingSinks {
    fun open(offer: TransferOffer): SinkResult
}

/** Dials a bulk connection (SPEC 13) and writes the hello. */
fun interface BulkOpener {
    suspend fun open(hello: BulkHello): BulkStream
}
