package io.github.anmirror.protocol

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Base64

class PairingUriException(val reason: Reason) : Exception(reason.name) {
    enum class Reason { UNSUPPORTED_VERSION, MALFORMED }
}

/** The content of the pairing QR code. Rules: protocol/SPEC.md section 5.2. */
data class PairingUri(
    val version: Int = 1,
    val macFingerprint: ByteArray,
    val secret: ByteArray,
    val hosts: List<String>,
    val port: Int,
    val macName: String,
) {
    fun toUriString(): String =
        PREFIX + "v=$version&fp=${b64Encode(macFingerprint)}&s=${b64Encode(secret)}" +
            "&h=${hosts.joinToString(",")}&p=$port&n=${percentEncode(macName)}"

    override fun equals(other: Any?): Boolean =
        other is PairingUri && version == other.version &&
            macFingerprint.contentEquals(other.macFingerprint) && secret.contentEquals(other.secret) &&
            hosts == other.hosts && port == other.port && macName == other.macName

    override fun hashCode(): Int {
        var h = version
        h = 31 * h + macFingerprint.contentHashCode()
        h = 31 * h + secret.contentHashCode()
        h = 31 * h + hosts.hashCode()
        h = 31 * h + port
        h = 31 * h + macName.hashCode()
        return h
    }

    // The secret must not leak into logs.
    override fun toString(): String = "PairingUri(version=$version, hosts=$hosts, port=$port, macName=$macName)"

    companion object {
        private const val PREFIX = "anmirror://pair?"

        private fun malformed(): Nothing = throw PairingUriException(PairingUriException.Reason.MALFORMED)

        fun parse(s: String): PairingUri {
            if (!s.startsWith(PREFIX)) malformed()
            val params = HashMap<String, String>()
            for (part in s.substring(PREFIX.length).split('&')) {
                if (part.isEmpty()) continue
                val eq = part.indexOf('=')
                val key = if (eq >= 0) part.substring(0, eq) else part
                val value = if (eq >= 0) part.substring(eq + 1) else ""
                if (params.put(key, value) != null) malformed()
            }

            // The version is checked before any other field.
            val version = canonicalUInt(params["v"] ?: malformed()) ?: malformed()
            if (version != 1L) throw PairingUriException(PairingUriException.Reason.UNSUPPORTED_VERSION)

            val fp = b64Decode(params["fp"] ?: malformed())?.takeIf { it.size == 32 } ?: malformed()
            val secret = b64Decode(params["s"] ?: malformed())?.takeIf { it.size == 32 } ?: malformed()
            val hosts = (params["h"] ?: malformed()).split(',')
            if (hosts.any { it.isEmpty() }) malformed()
            val port = canonicalUInt(params["p"] ?: malformed()) ?: malformed()
            if (port !in 1L..65535L) malformed()
            val name = percentDecode(params["n"] ?: "") ?: malformed()
            return PairingUri(1, fp, secret, hosts, port.toInt(), name)
        }

        /** ASCII `0|[1-9][0-9]*`. Values too large for Long saturate (still "canonical"). */
        private fun canonicalUInt(s: String): Long? {
            if (s.isEmpty() || s.any { it !in '0'..'9' }) return null
            if (s.length > 1 && s[0] == '0') return null
            return s.toLongOrNull() ?: Long.MAX_VALUE
        }

        private fun b64Encode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

        /** Canonical unpadded base64url only: re-encoding must reproduce the input. */
        private fun b64Decode(s: String): ByteArray? {
            val decoded = try {
                Base64.getUrlDecoder().decode(s)
            } catch (e: IllegalArgumentException) {
                return null
            }
            return if (b64Encode(decoded) == s) decoded else null
        }

        private fun percentEncode(s: String): String {
            val sb = StringBuilder()
            for (b in s.toByteArray(Charsets.UTF_8)) {
                val c = b.toInt() and 0xFF
                if (c in 0x41..0x5A || c in 0x61..0x7A || c in 0x30..0x39 || c == 0x2D || c == 0x2E || c == 0x5F || c == 0x7E) {
                    sb.append(c.toChar())
                } else {
                    sb.append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 15])
                }
            }
            return sb.toString()
        }

        private fun hexValue(c: Char): Int = when (c) {
            in '0'..'9' -> c - '0'
            in 'A'..'F' -> c - 'A' + 10
            in 'a'..'f' -> c - 'a' + 10
            else -> -1
        }

        private fun percentDecode(s: String): String? {
            val out = java.io.ByteArrayOutputStream()
            var i = 0
            while (i < s.length) {
                val c = s[i]
                when {
                    c == '%' -> {
                        if (i + 2 >= s.length) return null
                        val hi = hexValue(s[i + 1])
                        val lo = hexValue(s[i + 2])
                        if (hi < 0 || lo < 0) return null
                        out.write(hi shl 4 or lo)
                        i += 3
                    }
                    c.code >= 0x80 -> return null // raw non-ASCII
                    else -> {
                        out.write(c.code)
                        i++
                    }
                }
            }
            // Strict UTF-8 over the whole byte array (a NUL is a valid character, not a terminator).
            return try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(out.toByteArray()))
                    .toString()
            } catch (e: CharacterCodingException) {
                null
            }
        }
    }
}
