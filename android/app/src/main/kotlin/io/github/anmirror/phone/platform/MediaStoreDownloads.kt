package io.github.anmirror.phone.platform

import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import io.github.anmirror.phone.TAG
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferOffer
import io.github.anmirror.transfer.IncomingFile
import io.github.anmirror.transfer.IncomingSinks
import io.github.anmirror.transfer.SinkResult
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** A received file, for the "Saved to" notification's tap. */
data class SavedFile(val uri: Uri, val mime: String)

/**
 * Files from the Mac land in `Download/Android Mirroring` through MediaStore (no storage
 * permission). A row is inserted pending (`IS_PENDING = 1`) and published by [IncomingFile.commit];
 * MediaStore renames a colliding name to `name (1).ext`. Every failure deletes the row, and the
 * first open in a process deletes pending rows a killed process left behind. Offers with a
 * browse `target` are not for Downloads (Task 10 routes them). Blocking: call off the main thread.
 */
class MediaStoreDownloads(context: Context) : IncomingSinks {
    private val resolver: ContentResolver = context.contentResolver
    private val storage = context.getSystemService(StorageManager::class.java)
    private val swept = AtomicBoolean(false)
    private val saved = object : LinkedHashMap<String, SavedFile>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, SavedFile>?) = size > KEEP_SAVED
    }

    /** Bytes that can be written to shared storage now (the system may free cache to make room). */
    fun freeBytes(): Long = storage.getAllocatableBytes(StorageManager.UUID_DEFAULT)

    /** Where a recently received transfer was saved; null if unknown. */
    fun saved(transferId: String): SavedFile? = synchronized(saved) { saved[transferId] }

    override fun open(offer: TransferOffer): SinkResult {
        if (offer.hasTarget()) return SinkResult.Refused(TransferError.TRANSFER_ERROR_BAD_TARGET)
        if (swept.compareAndSet(false, true)) sweepLeftovers()
        val mime = mimeFor(offer)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, offer.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(COLLECTION, values) ?: throw IOException("insert refused")
        val out = try {
            resolver.openOutputStream(uri, "w") ?: throw IOException("no output stream")
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw e
        }
        return SinkResult.Ready(Download(offer.transferId, uri, mime, out))
    }

    private inner class Download(
        private val transferId: String,
        private val uri: Uri,
        private val mime: String,
        override val output: OutputStream,
    ) : IncomingFile {
        override fun commit(): String {
            output.close()
            val publish = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            if (resolver.update(uri, publish, null, null) < 1) throw IOException("publish refused")
            val name = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            } ?: throw IOException("saved name unknown")
            synchronized(saved) { saved[transferId] = SavedFile(uri, mime) }
            return name
        }

        /** Also after a [commit] that threw part way: the row goes, published or not. */
        override fun abort() {
            runCatching { output.close() }
            resolver.delete(uri, null, null)
        }
    }

    /** Deletes this app's pending rows in our folder: partial files from a process that was killed mid-transfer. */
    private fun sweepLeftovers() {
        try {
            val selection = "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.IS_PENDING}=1"
            val args = arrayOf("$RELATIVE_PATH/")
            val n = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                resolver.delete(
                    COLLECTION,
                    Bundle().apply {
                        putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                        putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
                        putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
                    },
                )
            } else {
                @Suppress("DEPRECATION")
                resolver.delete(MediaStore.setIncludePending(COLLECTION), selection, args)
            }
            if (n > 0) Log.i(TAG, "downloads: removed $n partial files")
        } catch (e: Exception) {
            Log.w(TAG, "downloads: leftover sweep failed (${e.javaClass.simpleName})")
        }
    }

    private fun mimeFor(offer: TransferOffer): String {
        offer.mime.trim().takeIf { '/' in it }?.let { return it }
        val ext = offer.name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: OCTET_STREAM
    }

    private companion object {
        val COLLECTION: Uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        const val RELATIVE_PATH = "Download/Android Mirroring"
        const val OCTET_STREAM = "application/octet-stream"
        const val KEEP_SAVED = 20
    }
}
