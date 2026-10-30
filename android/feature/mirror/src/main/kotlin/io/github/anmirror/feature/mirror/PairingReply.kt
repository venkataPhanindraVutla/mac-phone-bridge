package io.github.anmirror.feature.mirror

/** What the user typed into the pairing notification. */
sealed interface ReplyParse {
    data class Ok(val port: Int, val code: String) : ReplyParse
    data object Invalid : ReplyParse
}

/**
 * The pairing notification's reply: the six-digit code alone (`482916`, when NSD found the
 * pairing port), or the port and the code separated by spaces or a colon (`37123 482916`,
 * `37123:482916`). Surrounding whitespace is ignored; anything else is [ReplyParse.Invalid].
 */
object PairingReply {
    private val CODE = Regex("[0-9]{6}")
    private val PORT = Regex("[0-9]{1,5}")
    private val PORT_AND_CODE = Regex("([0-9]+)(?:\\s+|:)([0-9]+)")
    private const val MAX_PORT = 65_535

    fun parse(text: String, discoveredPort: Int?): ReplyParse {
        val t = text.trim()
        if (CODE.matches(t)) return discoveredPort?.let { ReplyParse.Ok(it, t) } ?: ReplyParse.Invalid
        val m = PORT_AND_CODE.matchEntire(t) ?: return ReplyParse.Invalid
        val (portText, code) = m.destructured
        if (!PORT.matches(portText) || !CODE.matches(code)) return ReplyParse.Invalid
        val port = portText.toInt()
        return if (port in 1..MAX_PORT) ReplyParse.Ok(port, code) else ReplyParse.Invalid
    }
}
