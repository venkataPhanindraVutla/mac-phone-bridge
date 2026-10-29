package io.github.anmirror.feature.screenshots

import android.content.ContentResolver
import android.content.ContentUris
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import io.github.anmirror.transfer.FileNames
import io.github.anmirror.transfer.OutgoingFile
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean

/** One MediaStore image, as the detector sees it. */
data class ImageRow(val id: Long, val relativePath: String?, val dateAddedSec: Long, val pending: Boolean, val name: String, val size: Long, val mime: String)

/** The phone's images. Both calls block (run them off the main thread) and return nothing when access is gone. */
interface ImageQuery {
    /**
     * Images in a screenshot folder added between [sinceSec] and [untilSec] (epoch seconds,
     * inclusive), newest first, at most a few dozen.
     */
    fun addedSince(sinceSec: Long, untilSec: Long): List<ImageRow>

    /** The image to send, or null when it can't be read. A [Closeable] result must be closed once its transfer ends. */
    fun open(id: Long): OutgoingFile?
}

/** [ImageQuery] over `MediaStore.Images` (READ_MEDIA_IMAGES, or READ_EXTERNAL_STORAGE up to API 32). */
class MediaStoreImageQuery(private val resolver: ContentResolver) : ImageQuery {
    override fun addedSince(sinceSec: Long, untilSec: Long): List<ImageRow> {
        val (selection, selectionArgs) = screenshotSelection(sinceSec, untilSec)
        val args = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs)
            putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, SCREENSHOT_SORT)
            putInt(ContentResolver.QUERY_ARG_LIMIT, LIMIT)
        }
        val rows = ArrayList<ImageRow>()
        try {
            resolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, COLUMNS, args, null)?.use { c ->
                val id = c.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val path = c.getColumnIndexOrThrow(MediaStore.Images.Media.RELATIVE_PATH)
                val added = c.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
                val pending = c.getColumnIndexOrThrow(MediaStore.Images.Media.IS_PENDING)
                val name = c.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                val size = c.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                val mime = c.getColumnIndexOrThrow(MediaStore.Images.Media.MIME_TYPE)
                while (c.moveToNext()) {
                    rows += ImageRow(
                        id = c.getLong(id),
                        relativePath = c.getString(path),
                        dateAddedSec = c.getLong(added),
                        pending = c.getInt(pending) != 0,
                        name = c.getString(name).orEmpty(),
                        size = c.getLong(size),
                        mime = c.getString(mime) ?: OCTET_STREAM,
                    )
                }
            }
        } catch (e: Exception) {
            // Access revoked, or a provider that answers no query: nothing to find.
            return emptyList()
        }
        return rows
    }

    override fun open(id: Long): OutgoingFile? {
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        var rawName: String? = null
        var mime: String? = null
        var modifiedSec = 0L
        try {
            val projection = arrayOf(
                MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.MIME_TYPE, MediaStore.Images.Media.DATE_MODIFIED,
            )
            resolver.query(uri, projection, null, null)?.use { c ->
                if (!c.moveToFirst()) return null
                rawName = c.getString(0)
                mime = c.getString(1)
                modifiedSec = if (c.isNull(2)) 0 else c.getLong(2)
            } ?: return null
        } catch (e: Exception) {
            return null
        }
        val pfd = try {
            resolver.openFileDescriptor(uri, "r")
        } catch (e: Exception) {
            null
        } ?: return null
        val size = pfd.statSize
        if (size < 0) {
            runCatching { pfd.close() }
            return null
        }
        return ImageFile(pfd, FileNames.sanitize(rawName ?: "Screenshot_$id.png"), size, mime ?: OCTET_STREAM, modifiedSec * 1_000)
    }

    private companion object {
        val COLUMNS = arrayOf(
            MediaStore.Images.Media._ID, MediaStore.Images.Media.RELATIVE_PATH, MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.IS_PENDING, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.MIME_TYPE,
        )
        /** More than a burst of screenshots within 30 s; as many as the detector remembers. */
        const val LIMIT = ScreenshotDetector.KEEP_IDS
        const val OCTET_STREAM = "application/octet-stream"
    }
}

/**
 * An image opened for sending: [open] hands the descriptor to the one stream that reads it;
 * [close] releases it whether or not it was read (call it when the transfer ends).
 */
class ImageFile(
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

/**
 * The query's selection: the time window, and the folder (so the LIMIT counts only screenshot
 * candidates, never a burst of other images). SQLite's LIKE ignores ASCII case, so
 * "Screenshots" and "Screenshot" folders both match; the detector checks the same again.
 */
internal fun screenshotSelection(sinceSec: Long, untilSec: Long): Pair<String, Array<String>> =
    "${MediaStore.Images.Media.DATE_ADDED}>=? AND ${MediaStore.Images.Media.DATE_ADDED}<=? AND " +
        "${MediaStore.Images.Media.RELATIVE_PATH} LIKE ?" to
        arrayOf(sinceSec.toString(), untilSec.toString(), "%${ScreenshotDetector.FOLDER}%")

/** Newest first, ties by ID, so a LIMIT drops the oldest. */
internal const val SCREENSHOT_SORT = "date_added DESC, _id DESC"
