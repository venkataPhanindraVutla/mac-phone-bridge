package io.github.anmirror.phone

/**
 * Which pairing-code hosts the phone may dial (ruling R27d). A QR code or link names the hosts,
 * and a link can come from any web page, so only local-network addresses are allowed:
 * private IPv4 (10/8, 172.16/12, 192.168/16), link-local 169.254/16, IPv6 fe80::/10 and
 * fc00::/7, and `*.local` (mDNS) names. Pure string checks: nothing is resolved here.
 */
object LanHosts {
    /** [hosts] in order, without any host that is not on the local network. */
    fun filter(hosts: List<String>): List<String> = hosts.filter(::isLan)

    fun isLan(host: String): Boolean {
        val h = host.trim()
        if (h.isEmpty() || h != host) return false
        ipv4(h)?.let { return isLanIpv4(it) }
        if (':' in h) return isLanIpv6(h)
        return isLocalName(h)
    }

    private fun isLanIpv4(a: IntArray): Boolean = when {
        a[0] == 10 -> true
        a[0] == 172 && a[1] in 16..31 -> true
        a[0] == 192 && a[1] == 168 -> true
        a[0] == 169 && a[1] == 254 -> true
        else -> false
    }

    /** Dotted-quad with canonical decimal parts, or null. */
    private fun ipv4(s: String): IntArray? {
        val parts = s.split('.')
        if (parts.size != 4) return null
        val out = IntArray(4)
        for ((i, p) in parts.withIndex()) {
            if (p.isEmpty() || p.length > 3 || !p.all { it in '0'..'9' }) return null
            if (p.length > 1 && p[0] == '0') return null
            out[i] = p.toInt().takeIf { it <= 255 } ?: return null
        }
        return out
    }

    private fun isLanIpv6(raw: String): Boolean {
        var s = raw
        if (s.startsWith("[") && s.endsWith("]")) s = s.substring(1, s.length - 1)
        s = s.substringBefore('%') // zone, e.g. fe80::1%wlan0
        val first = ipv6FirstHextet(s) ?: return false
        return (first and 0xffc0) == 0xfe80 || (first and 0xfe00) == 0xfc00
    }

    /** The first 16 bits of a valid IPv6 literal (no embedded IPv4 needed for our ranges), or null. */
    private fun ipv6FirstHextet(s: String): Int? {
        if (s.isEmpty() || s.count { it == ':' } < 2) return null
        if (!s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' || it == ':' }) return null
        val doubleColons = s.windowed(2).count { it == "::" }
        if (doubleColons > 1 || s.contains(":::")) return null
        val groups = s.split("::")
        val head = groups[0].takeIf { it.isNotEmpty() }?.split(':') ?: emptyList()
        val tail = if (groups.size == 2) groups[1].takeIf { it.isNotEmpty() }?.split(':') ?: emptyList() else emptyList()
        if ((head + tail).any { it.isEmpty() || it.length > 4 }) return null
        val count = head.size + tail.size
        if (groups.size == 1 && count != 8) return null
        if (groups.size == 2 && count > 7) return null
        return if (head.isEmpty()) 0 else head[0].toInt(16)
    }

    /** `name.local` or `a.b.local`, optionally with a trailing dot; DNS label characters only. */
    private fun isLocalName(s: String): Boolean {
        val name = s.removeSuffix(".")
        val labels = name.split('.')
        if (labels.size < 2 || !labels.last().equals("local", ignoreCase = true)) return false
        return labels.dropLast(1).all { label ->
            label.isNotEmpty() && label.length <= 63 &&
                label.all { it.isLetterOrDigit() && it.code < 128 || it == '-' } &&
                !label.startsWith('-') && !label.endsWith('-')
        }
    }
}
