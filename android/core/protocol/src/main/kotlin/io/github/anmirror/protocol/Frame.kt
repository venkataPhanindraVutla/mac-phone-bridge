package io.github.anmirror.protocol

import com.google.protobuf.ByteString
import com.google.protobuf.InvalidProtocolBufferException
import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope

class ProtocolException(val kind: Kind, message: String? = null) : Exception(message ?: kind.name) {
    enum class Kind { EMPTY_FRAME, FRAME_TOO_LARGE, MALFORMED }
}

/** Length-prefixed framing: 4-byte big-endian length, then the Envelope bytes. */
object Frame {
    const val MAX_BYTES = 1_048_576

    fun encode(envelope: Envelope): ByteArray {
        val size = envelope.serializedSize
        if (size == 0) throw ProtocolException(ProtocolException.Kind.EMPTY_FRAME)
        if (size > MAX_BYTES) throw ProtocolException(ProtocolException.Kind.FRAME_TOO_LARGE, "$size bytes")
        val out = ByteArray(4 + size)
        out[0] = (size ushr 24).toByte()
        out[1] = (size ushr 16).toByte()
        out[2] = (size ushr 8).toByte()
        out[3] = size.toByte()
        System.arraycopy(envelope.toByteArray(), 0, out, 4, size)
        return out
    }
}

/**
 * Incremental decoder: feed bytes with [append], pull envelopes with [next].
 * After [next] throws, the connection must be closed; the decoder is not reusable.
 * Not thread-safe.
 */
class FrameDecoder {
    private var buffer = ByteArray(1024)
    private var start = 0
    private var end = 0

    fun append(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size) {
        require(offset >= 0 && length >= 0 && offset + length <= bytes.size) { "bad range" }
        if (end + length > buffer.size) {
            val live = end - start
            val target = if (live + length <= buffer.size) buffer else ByteArray(maxOf(buffer.size * 2, live + length))
            System.arraycopy(buffer, start, target, 0, live)
            buffer = target
            start = 0
            end = live
        }
        System.arraycopy(bytes, offset, buffer, end, length)
        end += length
    }

    fun next(): Envelope? {
        val available = end - start
        if (available < 4) return null
        val length = (buffer[start].toInt() and 0xFF shl 24) or
            (buffer[start + 1].toInt() and 0xFF shl 16) or
            (buffer[start + 2].toInt() and 0xFF shl 8) or
            (buffer[start + 3].toInt() and 0xFF)
        // Judge the header alone: never wait for (or buffer) an oversized body.
        // length is a signed Int here; values >= 2^31 come out negative and are also too large.
        if (length == 0) throw ProtocolException(ProtocolException.Kind.EMPTY_FRAME)
        if (length < 0 || length > Frame.MAX_BYTES) {
            throw ProtocolException(ProtocolException.Kind.FRAME_TOO_LARGE, "length ${length.toUInt()}")
        }
        if (available < 4 + length) return null
        val body = ByteString.copyFrom(buffer, start + 4, length)
        start += 4 + length
        if (start == end) {
            start = 0
            end = 0
        }
        try {
            return Envelope.parseFrom(body)
        } catch (e: InvalidProtocolBufferException) {
            throw ProtocolException(ProtocolException.Kind.MALFORMED, e.message)
        }
    }
}

fun envelope(channel: Channel, id: Long, type: String, payload: MessageLite, replyTo: Long = 0): Envelope =
    Envelope.newBuilder()
        .setChannel(channel)
        .setId(id)
        .setReplyTo(replyTo)
        .setType(type)
        .setPayload(payload.toByteString())
        .build()
