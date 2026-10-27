package io.github.anmirror.protocol

import com.google.protobuf.ByteString
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.RingRequest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun load(name: String): JsonObject {
    val stream = checkNotNull(object {}.javaClass.classLoader.getResourceAsStream(name)) { "missing vector $name" }
    return Json.parseToJsonElement(stream.use { it.readBytes().decodeToString() }).jsonObject
}

private fun String.unhex(): ByteArray = ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }
private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }
private fun JsonObject.str(k: String) = getValue(k).jsonPrimitive.content
private fun JsonObject.arr(k: String): JsonArray = getValue(k).jsonArray

private fun envelopeFrom(e: JsonObject): Envelope = Envelope.newBuilder()
    .setChannelValue(e.getValue("channel").jsonPrimitive.int)
    .setId(e.getValue("id").jsonPrimitive.long)
    .setReplyTo(e.getValue("reply_to").jsonPrimitive.long)
    .setType(e.str("type"))
    .setPayload(ByteString.copyFrom(e.str("payload_hex").unhex()))
    .build()

class VectorTest {
    @Test
    fun framingVectors() {
        val file = load("framing.json")
        assertEquals(Frame.MAX_BYTES, file.getValue("max_frame_bytes").jsonPrimitive.int)
        val vectors = file.arr("vectors")
        assertTrue(vectors.isNotEmpty())
        for (v in vectors.map { it.jsonObject }) {
            val name = v.str("name")
            val env = envelopeFrom(v.getValue("envelope").jsonObject)
            assertEquals(v.str("frame_hex"), Frame.encode(env).hex(), "encode $name")
            val dec = FrameDecoder()
            dec.append(v.str("frame_hex").unhex())
            assertEquals(env, dec.next(), "decode $name")
            assertNull(dec.next())
        }
    }

    @Test
    fun decoderRejectsInvalidFrames() {
        val invalid = load("framing.json").arr("invalid")
        assertTrue(invalid.isNotEmpty())
        for (v in invalid.map { it.jsonObject }) {
            val dec = FrameDecoder()
            dec.append(v.str("frame_hex").unhex())
            val expected = when (val e = v.str("error")) {
                "emptyFrame" -> ProtocolException.Kind.EMPTY_FRAME
                "frameTooLarge" -> ProtocolException.Kind.FRAME_TOO_LARGE
                else -> error("unknown expected error $e")
            }
            val ex = assertFailsWith<ProtocolException>(v.str("name")) { dec.next() }
            assertEquals(expected, ex.kind, v.str("name"))
        }
        // Garbage protobuf body.
        val garbage = FrameDecoder()
        garbage.append(byteArrayOf(0, 0, 0, 2, 0xFF.toByte(), 0xFF.toByte()))
        assertEquals(ProtocolException.Kind.MALFORMED, assertFailsWith<ProtocolException> { garbage.next() }.kind)
    }

    @Test
    fun frameSizeBoundary() {
        val ok = FrameDecoder()
        ok.append(byteArrayOf(0x00, 0x10, 0x00, 0x00))
        assertNull(ok.next())
        val big = FrameDecoder()
        big.append(byteArrayOf(0x00, 0x10, 0x00, 0x01))
        assertEquals(ProtocolException.Kind.FRAME_TOO_LARGE, assertFailsWith<ProtocolException> { big.next() }.kind)
        val huge = Envelope.newBuilder().setChannel(Channel.CHANNEL_FIND)
            .setPayload(ByteString.copyFrom(ByteArray(Frame.MAX_BYTES))).build()
        assertEquals(ProtocolException.Kind.FRAME_TOO_LARGE, assertFailsWith<ProtocolException> { Frame.encode(huge) }.kind)
    }

    @Test
    fun decoderHandlesSplitAndCoalescedFrames() {
        val vectors = load("framing.json").arr("vectors").map { it.jsonObject }
        val a = vectors[0]
        val b = vectors[2]
        val wire = a.str("frame_hex").unhex() + b.str("frame_hex").unhex()
        val expected = listOf(envelopeFrom(a.getValue("envelope").jsonObject), envelopeFrom(b.getValue("envelope").jsonObject))

        val split = FrameDecoder()
        val got = mutableListOf<Envelope>()
        for (byte in wire) {
            split.append(byteArrayOf(byte))
            while (true) got += split.next() ?: break
        }
        assertEquals(expected, got)

        val joined = FrameDecoder()
        joined.append(wire)
        val got2 = mutableListOf<Envelope>()
        while (true) got2 += joined.next() ?: break
        assertEquals(expected, got2)

        // offset/length slices
        val sliced = FrameDecoder()
        sliced.append(byteArrayOf(9, 9) + wire + byteArrayOf(7), 2, wire.size)
        val got3 = mutableListOf<Envelope>()
        while (true) got3 += sliced.next() ?: break
        assertEquals(expected, got3)
    }

    @Test
    fun messageTypesAndEnvelopeHelper() {
        assertEquals("system.hello", MessageType.HELLO)
        assertEquals("find.state", MessageType.FIND_STATE)
        val env = envelope(Channel.CHANNEL_FIND, 6, MessageType.FIND_RING, RingRequest.getDefaultInstance())
        assertEquals("find.ring", env.type)
        assertEquals(Channel.CHANNEL_FIND, env.channel)
        assertEquals(6L, env.id)
        assertEquals(0L, env.replyTo)
        assertTrue(env.payload.isEmpty)
    }

    @Test
    fun cryptoVectors() {
        val file = load("crypto.json")
        val fps = file.arr("fingerprints").map { it.jsonObject }
        assertEquals(setOf("mac", "phone", "stranger"), fps.map { it.str("name") }.toSet())
        for (f in fps) {
            assertEquals(f.str("fp_hex"), PairingCrypto.fingerprint(f.str("cert_der_hex").unhex()).hex(), "fp ${f.str("name")}")
        }
        for (p in file.arr("proofs").map { it.jsonObject }) {
            val got = PairingCrypto.secretProof(p.str("secret_hex").unhex(), p.str("mac_fp_hex").unhex(), p.str("phone_fp_hex").unhex())
            assertEquals(p.str("proof_hex"), got.hex())
        }
        val codes = file.arr("codes").map { it.jsonObject }
        assertTrue(codes.any { it.str("code").startsWith("0") })
        for (c in codes) {
            assertEquals(c.str("code"), PairingCrypto.confirmationCode(c.str("mac_fp_hex").unhex(), c.str("phone_fp_hex").unhex()))
        }
        for (r in file.arr("rotating_ids").map { it.jsonObject }) {
            val key = r.str("key_hex").unhex()
            val secs = r.getValue("unix_seconds").jsonPrimitive.long
            assertEquals(r.str("rid"), PairingCrypto.rotatingId(key, secs))
            assertEquals(r.getValue("epoch").jsonPrimitive.long, secs / 900)
            assertTrue(PairingCrypto.matchesRotatingId(r.str("rid"), key, secs))
        }
    }

    @Test
    fun rotatingIdAcceptsAdjacentEpochsOnly() {
        val key = load("crypto.json").arr("rotating_ids")[0].jsonObject.str("key_hex").unhex()
        val now = 1_800_000_000L
        val rid = PairingCrypto.rotatingId(key, now)
        assertTrue(PairingCrypto.matchesRotatingId(rid, key, now))
        assertTrue(PairingCrypto.matchesRotatingId(rid, key, now + 900))
        assertTrue(PairingCrypto.matchesRotatingId(rid, key, now - 900))
        assertFalse(PairingCrypto.matchesRotatingId(rid, key, now + 1800))
        assertFalse(PairingCrypto.matchesRotatingId(rid, key, now - 1800))
        assertFalse(PairingCrypto.matchesRotatingId("0000000000000000", key, now))
        assertFalse(PairingCrypto.matchesRotatingId("", key, now))
    }

    @Test
    fun randomBytesAreRandom() {
        assertEquals(32, PairingCrypto.randomBytes(32).size)
        assertFalse(PairingCrypto.randomBytes(32).contentEquals(PairingCrypto.randomBytes(32)))
        assertEquals(0, PairingCrypto.randomBytes(0).size)
    }

    @Test
    fun pairingUriVectors() {
        val file = load("pairing_uri.json")
        val valid = file.arr("valid").map { it.jsonObject }
        val invalid = file.arr("invalid").map { it.jsonObject }
        assertTrue(valid.isNotEmpty() && invalid.isNotEmpty())
        for (v in valid) {
            val f = v.getValue("fields").jsonObject
            val parsed = PairingUri.parse(v.str("uri"))
            assertEquals(f.getValue("version").jsonPrimitive.int, parsed.version)
            assertEquals(f.str("fp_hex"), parsed.macFingerprint.hex())
            assertEquals(f.str("secret_hex"), parsed.secret.hex())
            assertEquals(f.arr("hosts").map { it.jsonPrimitive.content }, parsed.hosts)
            assertEquals(f.getValue("port").jsonPrimitive.int, parsed.port)
            assertEquals(f.str("mac_name"), parsed.macName)
            assertEquals(parsed, PairingUri.parse(parsed.toUriString()))
        }
        assertEquals(valid[0].str("uri"), PairingUri.parse(valid[0].str("uri")).toUriString())
        for (v in invalid) {
            val expected = when (val e = v.str("error")) {
                "malformed" -> PairingUriException.Reason.MALFORMED
                "unsupportedVersion" -> PairingUriException.Reason.UNSUPPORTED_VERSION
                else -> error("unknown expected error $e")
            }
            val ex = assertFailsWith<PairingUriException>(v.str("name")) { PairingUri.parse(v.str("uri")) }
            assertEquals(expected, ex.reason, v.str("name"))
        }
    }

    @Test
    fun pairingUriEqualityUsesArrayContents() {
        val a = PairingUri(1, ByteArray(32), ByteArray(32), listOf("h"), 1, "n")
        val b = PairingUri(1, ByteArray(32), ByteArray(32), listOf("h"), 1, "n")
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertContentEquals(a.secret, b.secret)
    }
}
