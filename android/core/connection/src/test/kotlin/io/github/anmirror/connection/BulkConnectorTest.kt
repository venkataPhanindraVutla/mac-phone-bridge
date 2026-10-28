package io.github.anmirror.connection

import com.google.protobuf.ByteString
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class BulkConnectorTest {
    private val token = ByteArray(32) { (it * 7 + 1).toByte() }
    private val hello = BulkHello.newBuilder()
        .setToken(ByteString.copyFrom(token))
        .setRole(BulkRole.BULK_ROLE_PHONE_SENDS)
        .build()

    /** Reads exactly one frame from [input], leaving the raw bytes after it unread. */
    private fun readFrame(input: InputStream): Envelope {
        val data = DataInputStream(input)
        val length = data.readInt()
        check(length in 1..1_048_576) { "bad length $length" }
        val body = ByteArray(length)
        data.readFully(body)
        return Envelope.parseFrom(body)
    }

    private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    @Test
    fun writesBulkHelloFrameFirst() = runBlocking {
        val seen = AtomicReference<Envelope>()
        TestMacServer { c -> seen.set(readFrame(c.socket.inputStream)) }.use { server ->
            val bulk = withTimeout(10_000) {
                BulkConnector(TlsConnector(Identities.phone)).open("127.0.0.1", server.port, Identities.MAC_FP, hello)
            }
            server.join()
            bulk.close()
        }
        val envelope = seen.get()
        assertEquals(Channel.CHANNEL_FILES, envelope.channel)
        assertEquals(1L, envelope.id)
        assertEquals(MessageType.BULK_HELLO, envelope.type)
        val decoded = BulkHello.parseFrom(envelope.payload)
        assertContentEquals(token, decoded.token.toByteArray())
        assertEquals(BulkRole.BULK_ROLE_PHONE_SENDS, decoded.role)
    }

    @Test
    fun wrongPinIsRejected() = runBlocking {
        TestMacServer(identity = Identities.stranger) { _ -> }.use { server ->
            assertFailsWith<IOException> {
                withTimeout(10_000) {
                    BulkConnector(TlsConnector(Identities.phone)).open("127.0.0.1", server.port, Identities.MAC_FP, hello)
                }
            }
            assertEquals(0, server.scriptsStarted.get(), "the handshake must not complete")
        }
    }

    @Test
    fun streamsCarryRawBytesBothWays() = runBlocking {
        val toMac = Random(1).nextBytes(3 * BULK_BUFFER_BYTES + 17)
        val toPhone = Random(2).nextBytes(BULK_BUFFER_BYTES + 5)
        val macGot = AtomicReference<ByteArray>()
        TestMacServer { c ->
            val input = c.socket.inputStream
            check(readFrame(input).type == MessageType.BULK_HELLO)
            // The receiver reads exactly `size` bytes and never waits for EOF (SPEC 13).
            val got = ByteArray(toMac.size)
            DataInputStream(input).readFully(got)
            macGot.set(got)
            c.socket.outputStream.write(toPhone)
            c.socket.outputStream.flush()
            // Keep the connection up until the phone has read everything and closes.
            c.awaitEof(10_000)
        }.use { server ->
            val bulk = withTimeout(10_000) {
                BulkConnector(TlsConnector(Identities.phone)).open("127.0.0.1", server.port, Identities.MAC_FP, hello)
            }
            val phoneGot = ByteArray(toPhone.size)
            withContext(Dispatchers.IO) {
                bulk.output.write(toMac)
                bulk.output.flush()
                DataInputStream(bulk.input).readFully(phoneGot)
            }
            bulk.close()
            server.join()
            assertContentEquals(sha256(toMac), sha256(macGot.get()))
            assertContentEquals(sha256(toPhone), sha256(phoneGot))
        }
    }
}
