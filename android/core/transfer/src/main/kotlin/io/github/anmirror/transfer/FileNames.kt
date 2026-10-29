package io.github.anmirror.transfer

import java.text.Normalizer
import java.util.Locale

/** The SPEC 16 file-name rule, identical to the Mac side (`protocol/vectors/filenames.json`). */
object FileNames {
    private const val MAX_BYTES = 255
    private const val MAX_EXT_BYTES = 16

    /** Collision key: Unicode NFC, then locale-independent lowercase. */
    fun key(name: String): String = Normalizer.normalize(name, Normalizer.Form.NFC).lowercase(Locale.ROOT)

    fun sanitize(raw: String): String {
        val tail = raw.substring(maxOf(raw.lastIndexOf('/'), raw.lastIndexOf('\\')) + 1)
        val cleaned = tail.filterNot(::isStripped)
        val trimmed = cleaned.trimStart { it == '.' || it == ' ' }.trimEnd(' ')
        if (trimmed.isEmpty()) return "file"
        if (utf8(trimmed) <= MAX_BYTES) return trimmed
        val (stem, ext) = split(trimmed)
        val cut = cut(stem, MAX_BYTES - utf8(ext)).trimEnd(' ', '.')
        return (cut.ifEmpty { "file" }) + ext
    }

    /** [name] if `exists(name)` is false, else the first free `stem (n).ext`, within 255 bytes. */
    fun unique(name: String, exists: (String) -> Boolean): String {
        if (!exists(name)) return name
        val (stem, ext) = split(name)
        var n = 1
        while (true) {
            val suffix = " ($n)"
            val room = MAX_BYTES - utf8(ext) - utf8(suffix)
            var base = stem
            if (utf8(base) > room) base = cut(base, room).trimEnd(' ', '.')
            val candidate = base + suffix + ext
            if (!exists(candidate)) return candidate
            n++
        }
    }

    private fun isStripped(c: Char): Boolean =
        c.code <= 0x1F || c.code == 0x7F || c.code in 0x202A..0x202E || c.code in 0x2066..0x2069

    /** Splits at the last dot into (stem, ext incl. dot); no extension when it is over 16 bytes. */
    private fun split(name: String): Pair<String, String> {
        val dot = name.lastIndexOf('.')
        if (dot <= 0) return name to ""
        val ext = name.substring(dot)
        return if (utf8(ext) <= MAX_EXT_BYTES) name.substring(0, dot) to ext else name to ""
    }

    private fun utf8(s: String): Int {
        var n = 0
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            n += when {
                cp < 0x80 -> 1
                cp < 0x800 -> 2
                cp < 0x10000 -> 3
                else -> 4
            }
            i += Character.charCount(cp)
        }
        return n
    }

    /** The longest prefix of [s] within [maxBytes] UTF-8 bytes, cut on a scalar boundary. */
    private fun cut(s: String, maxBytes: Int): String {
        var n = 0
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            val b = when {
                cp < 0x80 -> 1
                cp < 0x800 -> 2
                cp < 0x10000 -> 3
                else -> 4
            }
            if (n + b > maxBytes) break
            n += b
            i += Character.charCount(cp)
        }
        return s.substring(0, i)
    }
}
