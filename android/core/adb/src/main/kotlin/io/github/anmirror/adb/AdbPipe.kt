package io.github.anmirror.adb

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** One ADB stream (`localabstract:…`, `exec:…`, `shell:…`) as plain streams. [close] runs [closer] once. */
class AdbPipe(val input: InputStream, val output: OutputStream, private val closer: () -> Unit) : Closeable {
    private val closed = AtomicBoolean(false)

    override fun close() {
        if (closed.compareAndSet(false, true)) closer()
    }
}
