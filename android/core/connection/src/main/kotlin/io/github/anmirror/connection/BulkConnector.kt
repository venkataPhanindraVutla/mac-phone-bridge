package io.github.anmirror.connection

import io.github.anmirror.protocol.Frame
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.envelope
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.Channel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Opens bulk connections to the Mac's second listener (SPEC 13). The phone always dials. */
class BulkConnector(private val connector: TlsConnector) {
    /** Dials the Mac's bulk port pinned to [pinnedFpHex], writes the `bulk.hello` frame, returns the stream. */
    suspend fun open(host: String, port: Int, pinnedFpHex: String, hello: BulkHello): BulkSocket {
        val bulk = BulkSocket(connector.dialPinned(host, port, pinnedFpHex))
        try {
            withContext(Dispatchers.IO) {
                bulk.output.write(Frame.encode(envelope(Channel.CHANNEL_FILES, 1, MessageType.BULK_HELLO, hello)))
                // Out now: the Mac waits for the hello before it sends or reads anything.
                bulk.output.flush()
            }
        } catch (t: Throwable) {
            bulk.close()
            throw t
        }
        return bulk
    }
}
