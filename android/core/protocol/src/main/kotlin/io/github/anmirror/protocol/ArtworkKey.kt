package io.github.anmirror.protocol

import java.security.MessageDigest

/**
 * Identifies a piece of media artwork: lowercase hex of the first 8 bytes of SHA-256 over the
 * JPEG bytes, or "" when there is no artwork. protocol/SPEC.md section 20.
 */
object ArtworkKey {
    fun of(jpeg: ByteArray): String {
        if (jpeg.isEmpty()) return ""
        return MessageDigest.getInstance("SHA-256").digest(jpeg).copyOf(8).joinToString("") { "%02x".format(it) }
    }
}
