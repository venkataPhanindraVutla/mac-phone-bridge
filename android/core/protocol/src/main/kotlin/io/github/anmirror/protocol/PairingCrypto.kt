package io.github.anmirror.protocol

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Fingerprints, pairing proofs, confirmation codes, rotating IDs and BLE IDs.
 * Definitions: protocol/SPEC.md sections 4, 5.1, 6 and 22.
 */
object PairingCrypto {
    private val proofLabel = "anmirror-pair-v1".toByteArray(Charsets.US_ASCII)
    private val sasLabel = "anmirror-sas-v1".toByteArray(Charsets.US_ASCII)
    private val bleLabel = "anmirror-ble-v1".toByteArray(Charsets.US_ASCII)
    private val ridLabel = "anmirror-rid-v1".toByteArray(Charsets.US_ASCII)
    private const val EPOCH_SECONDS = 900L

    /** Service UUID of the proximity advertisement (SPEC section 22). */
    const val BLE_SERVICE_UUID = "3d30288c-0f47-4016-a6ba-44506f920431"
    private val random = SecureRandom()

    /** SHA-256 of the certificate DER, 32 raw bytes. */
    fun fingerprint(certDer: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(certDer)

    fun secretProof(secret: ByteArray, macFp: ByteArray, phoneFp: ByteArray): ByteArray =
        hmac(secret, proofLabel + macFp + phoneFp)

    /** Six digits, zero-padded. */
    fun confirmationCode(macFp: ByteArray, phoneFp: ByteArray): String {
        val h = MessageDigest.getInstance("SHA-256").digest(sasLabel + macFp + phoneFp)
        val value = (h[0].toLong() and 0xFF shl 24) or (h[1].toLong() and 0xFF shl 16) or
            (h[2].toLong() and 0xFF shl 8) or (h[3].toLong() and 0xFF)
        return (value % 1_000_000).toString().padStart(6, '0')
    }

    /** 16 lowercase hex characters for the 15-minute epoch containing [unixSeconds]. */
    fun rotatingId(discoveryKey: ByteArray, unixSeconds: Long): String =
        rotatingIdForEpoch(discoveryKey, Math.floorDiv(unixSeconds, EPOCH_SECONDS))

    /** Accepts the epoch before, of, and after [unixSeconds]. */
    fun matchesRotatingId(rid: String, discoveryKey: ByteArray, unixSeconds: Long): Boolean {
        val epoch = Math.floorDiv(unixSeconds, EPOCH_SECONDS)
        val given = rid.toByteArray(Charsets.UTF_8)
        var matched = false
        for (e in (epoch - 1)..(epoch + 1)) {
            val expected = rotatingIdForEpoch(discoveryKey, e).toByteArray(Charsets.UTF_8)
            if (MessageDigest.isEqual(expected, given)) matched = true
        }
        return matched
    }

    /** The 15-minute epoch containing [unixSeconds]: floor(unix / 900). */
    fun epochOf(unixSeconds: Long): Long = Math.floorDiv(unixSeconds, EPOCH_SECONDS)

    /** The 8-byte BLE advertisement ID: HMAC-SHA256(discoveryKey, "anmirror-ble-v1" || phoneFp || uint64_be(epoch))[0..8]. */
    fun bleId(discoveryKey: ByteArray, phoneFp: ByteArray, epoch: Long): ByteArray {
        val epochBytes = ByteArray(8) { (epoch ushr (56 - 8 * it)).toByte() }
        return hmac(discoveryKey, bleLabel + phoneFp + epochBytes).copyOf(8)
    }

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    private fun rotatingIdForEpoch(discoveryKey: ByteArray, epoch: Long): String {
        val epochBytes = ByteArray(8) { (epoch ushr (56 - 8 * it)).toByte() }
        return hmac(discoveryKey, ridLabel + epochBytes).copyOf(8).joinToString("") { "%02x".format(it) }
    }

    private fun hmac(key: ByteArray, message: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(message)
    }
}
