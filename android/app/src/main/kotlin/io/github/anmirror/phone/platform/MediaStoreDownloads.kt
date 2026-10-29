package io.github.anmirror.phone.platform

import android.content.ContentResolver
import android.content.ContentValues
import android.content.ContentUris
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

private const val RELATIVE_PATH = "Download/Android Mirroring"

/**
 * The sweep's selection: pending rows in our folder that this app owns, except [liveIds] (rows
 * being written right now). MediaStore stores the folder with a trailing slash.
 */
internal fun leftoverSelection(ownerPackage: String, liveIds: Collection<Long>): Pair<String, Array<String>> {
    val selection = StringBuilder(
        "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.IS_PENDING}=1" +
            " AND ${MediaStore.MediaColumns.OWNER_PACKAGE_NAME}=?",
    )
    if (liveIds.isNotEmpty()) {
        selection.append(" AND ${MediaStore.MediaColumns._ID} NOT IN (${liveIds.joinToString(",") { "?" }})")
    }
    val args = listOf("$RELATIVE_PATH/", ownerPackage) + liveIds.map { it.toString() }
    return selection.toString() to args.toTypedArray()
}

/** A received file, for the "Saved to" notification's tap. */
data class SavedFile(val uri: Uri, val mime: String)

/**
 * Files from the Mac land in `Download/Android Mirroring` through MediaStore (no storage
 * permission). A row is inserted pending (`IS_PENDING = 1`) and published by [IncomingFile.commit];
 * MediaStore renames a colliding name to `name (1).ext`. Every failure deletes the row; pending
 * rows left behind (a killed process, a delete that threw) are swept when the connection service
 * starts and before the first open in a process, skipping rows being written. Offers with a
 * browse `target` are not for Downloads (Task 10 routes them). Blocking: call off the main thread.
 */
class MediaStoreDownloads(context: Context) : IncomingSinks {
    private val resolver: ContentResolver = context.contentResolver
    private val ownPackage = context.packageName
    private val storage = context.getSystemService(StorageManager::class.java)
    private val swept = AtomicBoolean(false)

    /** Row IDs of downloads being written: the sweep leaves them alone. Also the sweep's lock. */
    private val live = HashSet<Long>()
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
        // Under the sweep's lock: a sweep can't run between the insert and the row being marked live.
        val (uri, rowId) = synchronized(live) {
            val uri = resolver.insert(COLLECTION, values) ?: throw IOException("insert refused")
            val rowId = ContentUris.parseId(uri)
            live += rowId
            uri to rowId
        }
        val out = try {
            resolver.openOutputStream(uri, "w") ?: throw IOException("no output stream")
        } catch (e: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            synchronized(live) { live -= rowId }
            throw e
        }
        return SinkResult.Ready(Download(offer.transferId, uri, rowId, mime, out))
    }

    private inner class Download(
        private val transferId: String,
        private val uri: Uri,
        private val rowId: Long,
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
            synchronized(live) { live -= rowId }
            return name
        }

        /** Also after a [commit] that threw part way: the row goes, published or not. */
        override fun abort() {
            runCatching { output.close() }
            try {
                resolver.delete(uri, null, null)
            } finally {
                synchronized(live) { live -= rowId } // a failed delete is left to the next sweep
            }
        }
    }

    /**
     * Deletes this app's pending rows in our folder, except those being written: partial files a
     * killed process or a failed delete left behind. Blocking; never throws.
     */
    fun sweepLeftovers() {
        try {
            synchronized(live) { sweepLocked() }
        } catch (e: Exception) {
            Log.w(TAG, "downloads: leftover sweep failed (${e.javaClass.simpleName})")
        }
    }

    private fun sweepLocked() {
        val (selection, args) = leftoverSelection(ownPackage, live.toList())
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
    }

    private fun mimeFor(offer: TransferOffer): String {
        offer.mime.trim().takeIf { '/' in it }?.let { return it }
        val ext = offer.name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: OCTET_STREAM
    }

    private companion object {
        val COLLECTION: Uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        const val OCTET_STREAM = "application/octet-stream"
        const val KEEP_SAVED = 20
    }
}
