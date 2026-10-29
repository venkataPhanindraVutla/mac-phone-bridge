package io.github.anmirror.phone.platform

import android.content.ContentResolver
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.github.anmirror.transfer.FileNames
import io.github.anmirror.transfer.OutgoingFile
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A shared file, opened while the share's URI grant was live: the descriptor outlives the
 * activity, so nothing is copied. [open] hands the descriptor to the one stream that reads it;
 * [close] releases it whether or not it was read (call it when the transfer ends).
 */
class SharedFile(
    private val pfd: ParcelFileDescriptor,
    override val name: String,
    override val size: Long,
    override val mime: String,
    override val modifiedMs: Long,
) : OutgoingFile, Closeable {
    private val opened = AtomicBoolean(false)

    override fun open(): InputStream {
        if (!opened.compareAndSet(false, true)) throw IOException("already read")
        return ParcelFileDescriptor.AutoCloseInputStream(pfd)
    }

    override fun close() {
        runCatching { pfd.close() }
    }
}

/** Opening a shared URI: a file to send, or why not (with the name to show, when known). */
sealed interface SharedUri {
    data class Ready(val file: SharedFile) : SharedUri
    data class Unreadable(val name: String) : SharedUri
}

object UriSources {
    private const val OCTET_STREAM = "application/octet-stream"
    private const val UNNAMED = "file"

    /**
     * Opens [uri] for reading and reads its `DISPLAY_NAME` and `SIZE` (else the descriptor's
     * size). A file whose size can't be known can't be offered, so it is [SharedUri.Unreadable].
     * Call while the grant is live (in the share activity's `onCreate`).
     */
    fun open(resolver: ContentResolver, uri: Uri): SharedUri {
        var rawName: String? = null
        var size: Long? = null
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0 && !c.isNull(n)) rawName = c.getString(n)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                }
            }
        } catch (e: Exception) {
            // Some providers answer no query: the descriptor still gives the size.
        }
        val name = FileNames.sanitize(rawName ?: uri.lastPathSegment ?: UNNAMED)
        val pfd = try {
            resolver.openFileDescriptor(uri, "r")
        } catch (e: Exception) {
            null
        } ?: return SharedUri.Unreadable(name)
        val bytes = size?.takeIf { it >= 0 } ?: pfd.statSize.takeIf { it >= 0 }
        if (bytes == null) {
            runCatching { pfd.close() }
            return SharedUri.Unreadable(name)
        }
        val mime = runCatching { resolver.getType(uri) }.getOrNull() ?: OCTET_STREAM
        return SharedUri.Ready(SharedFile(pfd, name, bytes, mime, modifiedMs = 0))
    }
}
