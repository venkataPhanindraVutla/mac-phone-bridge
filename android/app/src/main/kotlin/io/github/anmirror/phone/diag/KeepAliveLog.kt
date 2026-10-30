package io.github.anmirror.phone.diag

import java.io.File
import java.time.Instant

/** Events worth knowing when the connection service disappears. Codes only, never content. */
enum class KeepAliveEvent(val code: String) {
    PROCESS_START("process-start"), APP_OPEN("app-open"),
    SERVICE_CREATE("service-create"), SERVICE_START("service-start"), SERVICE_DESTROY("service-destroy"),
    SERVICE_SELF_STOP("service-self-stop"), STATE("state"), STORE_UNREADABLE("store-unreadable"),
    SCREEN_ON("screen-on"), NETWORK("network"), WATCHDOG("watchdog"), EXEMPT("exempt"),
    SOCKET_TUNE("socket-tune"),
}

/**
 * A small content-free event log: one line per event, `<UTC time> <code> <detail>`, newest
 * [maxLines] kept. The detail is sanitised to `[A-Za-z0-9_=.,-]` (no spaces, quotes or
 * punctuation), but that is not a privacy filter: callers pass only codes, booleans, counts and
 * class names, never a Mac name, host, address or text. Writes are synchronous (a line is tiny)
 * and never throw.
 */
class KeepAliveLog(
    private val file: File,
    private val maxLines: Int = 500,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val lock = Any()
    private var lines = -1

    fun record(event: KeepAliveEvent, detail: String = "") {
        try {
            val clean = detail.replace(UNSAFE, "_")
            val line = buildString {
                append(Instant.ofEpochMilli(clock())).append(' ').append(event.code)
                if (clean.isNotEmpty()) append(' ').append(clean)
                append('\n')
            }
            synchronized(lock) {
                if (lines < 0) lines = if (file.exists()) file.readLines().size else 0
                file.appendText(line)
                lines++
                if (lines > maxLines + SLACK) {
                    val kept = file.readLines().takeLast(maxLines)
                    file.writeText(kept.joinToString("\n", postfix = "\n"))
                    lines = kept.size
                }
            }
        } catch (_: Throwable) {
            synchronized(lock) { lines = -1 }
        }
    }

    private companion object {
        const val SLACK = 100
        val UNSAFE = Regex("[^A-Za-z0-9_=.,-]")
    }
}
