package io.github.anmirror.connection

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import javax.net.ssl.SSLSocket

/** Read and write buffer size for bulk connections (256 KiB). */
const val BULK_BUFFER_BYTES = 256 * 1024

/** A bulk connection after its `bulk.hello`: raw bytes both ways (SPEC 13). */
interface BulkStream : Closeable {
    val input: InputStream
    val output: OutputStream

    /** Sets the socket's send buffer (the mirror relay asks for 256 KiB); a stream without a socket ignores it. */
    fun setSendBufferBytes(n: Int) {}
}

/**
 * [BulkStream] over a pinned TLS socket, with [BULK_BUFFER_BYTES] buffered streams. Blocking:
 * use it off the main thread. Android's SSLSocket has no `shutdownOutput`, so a receiver reads
 * exactly the announced size and never waits for EOF; [close] ends both directions.
 */
class BulkSocket internal constructor(private val socket: SSLSocket) : BulkStream {
    override val input: InputStream = BufferedInputStream(socket.inputStream, BULK_BUFFER_BYTES)
    override val output: OutputStream = BufferedOutputStream(socket.outputStream, BULK_BUFFER_BYTES)

    override fun setSendBufferBytes(n: Int) {
        socket.sendBufferSize = n
    }

    /**
     * Aborts: closes the socket at once and **discards any bytes still buffered in [output]**.
     * On the success path, call `output.flush()` before closing.
     */
    override fun close() {
        runCatching { socket.close() }
    }
}
