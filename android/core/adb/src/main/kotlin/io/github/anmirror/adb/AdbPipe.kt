package io.github.anmirror.adb

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One ADB stream (`localabstract:…`, `exec:…`, `shell:…`) as plain streams. [close] runs [closer]
 * once. [queuedBytes] is what the device has sent that [input] has not yet given out (libadb
 * acknowledges every chunk at once and keeps it in memory); null when it can't be measured.
 */
class AdbPipe(
    val input: InputStream,
    val output: OutputStream,
    val queuedBytes: () -> Long? = { null },
    private val closer: () -> Unit,
) : Closeable {
    private val closed = AtomicBoolean(false)

    override fun close() {
        if (closed.compareAndSet(false, true)) closer()
    }
}
