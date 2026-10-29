package io.github.anmirror.feature.photos

import android.content.ContentResolver
import android.content.ContentUris
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.util.Size
import io.github.anmirror.transfer.FileNames
import io.github.anmirror.transfer.OutgoingFile
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** One photo or video, as `photos.items` lists it (SPEC 18). */
data class MediaItem(
    val id: Long,
    val dateTakenMs: Long,
    val mime: String,
    val width: Int,
    val height: Int,
    val durationMs: Long,
    val video: Boolean,
)

/**
 * The phone's photos and videos, in one ID space. Every call blocks (run it off the main thread)
 * and returns nothing when access is gone. With partial access (API 34+) only the picked items
 * are seen.
 */
interface MediaLibrary {
    /** At most [limit] items, newest first; with [beforeMs] > 0 only those added before it. */
    fun recent(limit: Int, beforeMs: Long): List<MediaItem>

    /** The item's thumbnail as a JPEG within the wire limits, or null when there is none. */
    fun thumbnail(id: Long): ByteArray?

    /** The item to send, or null when it can't be read. A [java.io.Closeable] result must be closed once its transfer ends. */
    fun file(id: Long): OutgoingFile?
}

/**
 * [MediaLibrary] over `MediaStore.Files` ("external"), images and videos together, so photos and
 * videos share one ID space. Needs READ_MEDIA_IMAGES + READ_MEDIA_VIDEO (API 33+), or
 * READ_EXTERNAL_STORAGE; with READ_MEDIA_VISUAL_USER_SELECTED alone (API 34+) MediaStore returns
 * only the picked items. Pending and trashed rows are left out by MediaStore itself.
 */
class MediaStoreLibrary(private val resolver: ContentResolver) : MediaLibrary {
    /** Whether each listed ID is a video, from the last [recent], so a thumbnail or file needs no extra query. */
    private val kinds = ConcurrentHashMap<Long, Boolean>()

    override fun recent(limit: Int, beforeMs: Long): List<MediaItem> {
        val (selection, selectionArgs) = recentSelection(beforeMs)
        val items = ArrayList<MediaItem>()
        // Only what the newest listing holds (anything else is looked up again when asked for).
        kinds.clear()
        try {
            query(selection, selectionArgs, limit)?.use { c ->
                val id = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val type = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
                val taken = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
                val added = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
                val mime = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                val width = c.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
                val height = c.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
                val duration = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DURATION)
                while (c.moveToNext() && items.size < limit) {
                    val video = c.getInt(type) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                    val item = MediaItem(
                        id = c.getLong(id),
                        dateTakenMs = dateTakenMs(
                            if (c.isNull(taken)) null else c.getLong(taken),
                            if (c.isNull(added)) 0 else c.getLong(added),
                        ),
                        mime = c.getString(mime) ?: if (video) "video/*" else "image/*",
                        width = if (c.isNull(width)) 0 else c.getInt(width),
                        height = if (c.isNull(height)) 0 else c.getInt(height),
                        durationMs = if (!video || c.isNull(duration)) 0 else c.getLong(duration),
                        video = video,
                    )
                    items += item
                    kinds[item.id] = video
                }
            }
        } catch (e: Exception) {
            // Access revoked, or a provider that answers no query: nothing to list.
            return emptyList()
        }
        return items
    }

    override fun thumbnail(id: Long): ByteArray? {
        val uri = uriFor(id) ?: return null
        val bitmap = try {
            resolver.loadThumbnail(uri, Size(ThumbnailEncoder.EDGE, ThumbnailEncoder.EDGE), null)
        } catch (e: Exception) {
            // IOException when none can be made; SecurityException when access went.
            return null
        }
        return try {
            ThumbnailEncoder.toJpeg(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    override fun file(id: Long): OutgoingFile? {
        val uri = uriFor(id) ?: return null
        var rawName: String? = null
        var mime: String? = null
        var modifiedSec = 0L
        try {
            val projection = arrayOf(
                MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.DATE_MODIFIED,
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
        val fallback = if (kinds[id] == true) "VID_$id.mp4" else "IMG_$id.jpg"
        return MediaFile(pfd, FileNames.sanitize(rawName ?: fallback), size, mime ?: OCTET_STREAM, modifiedSec * 1_000)
    }

    /** API 30+ takes the limit as a query argument; API 29's MediaProvider only reads it from the sort order. */
    private fun query(selection: String, selectionArgs: Array<String>, limit: Int): Cursor? {
        val uri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val args = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs)
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, RECENT_SORT)
                putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
            }
            resolver.query(uri, COLUMNS, args, null)
        } else {
            resolver.query(uri, COLUMNS, selection, selectionArgs, "$RECENT_SORT LIMIT $limit")
        }
    }

    /** The image or video URI of [id]: thumbnails and descriptors come from the typed collections. */
    private fun uriFor(id: Long): Uri? {
        val video = kinds[id] ?: lookUpKind(id) ?: return null
        val collection = if (video) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        return ContentUris.withAppendedId(collection, id)
    }

    /** Whether [id] is a video (null: not an image or video this app can see). */
    private fun lookUpKind(id: Long): Boolean? = try {
        val uri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val selection = "${MediaStore.Files.FileColumns._ID}=? AND ${MEDIA_TYPES_SELECTION}"
        resolver.query(uri, arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE), selection, arrayOf(id.toString()), null)?.use { c ->
            if (c.moveToFirst()) (c.getInt(0) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO).also { kinds[id] = it } else null
        }
    } catch (e: Exception) {
        null
    }

    private companion object {
        val COLUMNS = arrayOf(
            MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.MEDIA_TYPE, MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT, MediaStore.MediaColumns.DURATION,
        )
        const val OCTET_STREAM = "application/octet-stream"
    }
}

/**
 * A photo or video opened for sending: [open] hands the descriptor to the one stream that reads
 * it; [close] releases it whether or not it was read (call it when the transfer ends).
 */
class MediaFile(
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

/** Images and videos only (`MEDIA_TYPE` 1 and 3). */
internal val MEDIA_TYPES_SELECTION =
    "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}," +
        "${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"

/** Images and videos, and with [beforeMs] > 0 only those added before it (the list's own sort key). */
internal fun recentSelection(beforeMs: Long): Pair<String, Array<String>> =
    if (beforeMs > 0) {
        "$MEDIA_TYPES_SELECTION AND ${MediaStore.MediaColumns.DATE_ADDED}<?" to arrayOf((beforeMs / 1_000).toString())
    } else {
        MEDIA_TYPES_SELECTION to emptyArray()
    }

/**
 * Newest added first, ties by ID. Each column has its own DESC: `QUERY_ARG_SORT_DIRECTION` would
 * apply to the last column only.
 */
internal const val RECENT_SORT = "date_added DESC, _id DESC"

/** `date_taken_ms`: DATE_TAKEN (ms) when set, else DATE_ADDED (s) × 1000. */
internal fun dateTakenMs(dateTakenMs: Long?, dateAddedSec: Long): Long =
    dateTakenMs?.takeIf { it > 0 } ?: (dateAddedSec * 1_000)
