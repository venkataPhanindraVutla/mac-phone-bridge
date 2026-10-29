package io.github.anmirror.feature.photos

import com.google.protobuf.MessageLite
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.BulkRole
import io.github.anmirror.protocol.v1.PhotoFetch
import io.github.anmirror.protocol.v1.PhotoItem
import io.github.anmirror.protocol.v1.PhotosList
import io.github.anmirror.protocol.v1.PhotosListRequest
import io.github.anmirror.protocol.v1.PhotosThumbsRequest
import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferFailed
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.transfer.BulkOpener
import io.github.anmirror.transfer.OutgoingFile
import io.github.anmirror.transfer.ThumbRecords
import io.github.anmirror.transfer.TransferEngine
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

/**
 * Phone side of `photos.*` (SPEC 18). The caller checks that the feature is open (the Mac shares
 * photos.v1, the switch is on, some photos are readable) before handing a request over, and
 * [send] sends only while it still is. Logs carry IDs and counts only, never names or bytes.
 *
 * [onQueued] gets each photo queued for sending with its transfer ID, so its descriptor can be
 * closed when the transfer ends.
 */
class PhotosService(
    private val library: MediaLibrary,
    private val send: suspend (String, MessageLite) -> Boolean,
    private val bulk: BulkOpener,
    private val transfers: TransferEngine,
    private val partial: () -> Boolean,
    private val onQueued: (String, OutgoingFile) -> Unit = { _, _ -> },
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val stallMs: Long = STALL_MS,
    private val log: (String) -> Unit = {},
) {
    /**
     * The thumbnail stream being written, and the newest request's generation. A newer request,
     * or [stop], closes the stream. Taking over [current] and checking [generation] happen together
     * under [lock], so an older request can never close a newer one's stream.
     */
    private val lock = Any()
    private var current: BulkStream? = null
    private val generation = AtomicLong(0)

    /** `photos.list`: answered by `photos.items`, newest first, `limit` clamped to 1..200. */
    suspend fun onList(r: PhotosListRequest) {
        // uint32 on the wire: a value past Int.MAX_VALUE reads as negative here, and is a big ask.
        val limit = if (r.limit < 0) MAX_ITEMS else r.limit.coerceIn(1, MAX_ITEMS)
        val items = withContext(io) { library.recent(limit, r.beforeMs) }.take(limit)
        val list = PhotosList.newBuilder()
            .setRequestId(r.requestId)
            .setPartialAccess(partial())
            .addAllItems(items.map { it.toProto() })
            .build()
        send(MessageType.PHOTOS_ITEMS, list)
        log("photos: listed ${items.size}")
    }

    /**
     * `photos.thumbs`: at most 200 IDs, answered over one bulk connection (role THUMBNAILS) with a
     * record per ID in request order (empty when there is no thumbnail), then the end record. A
     * newer request, [stop], or 30 s without a byte moving closes the stream. Never throws for a
     * dial or write failure: the Mac sees the stream end early.
     */
    suspend fun onThumbs(r: PhotosThumbsRequest) {
        val ids = r.idsList.take(MAX_IDS)
        val gen = generation.incrementAndGet()
        val hello = BulkHello.newBuilder().setToken(r.token).setRole(BulkRole.BULK_ROLE_THUMBNAILS).build()
        val stream = try {
            bulk.open(hello)
        } catch (e: IOException) {
            log("photos: thumbnail dial failed (${e.javaClass.simpleName})")
            return
        }
        var stale = false
        val older = synchronized(lock) {
            if (generation.get() != gen) {
                stale = true
                null
            } else {
                current.also { current = stream }
            }
        }
        if (stale) {
            // A newer request came while this one dialed.
            stream.close()
            return
        }
        older?.close()
        val moved = AtomicLong(System.nanoTime())
        try {
            withContext(io) {
                val watchdog = launch {
                    while (true) {
                        delay(minOf(stallMs, 1_000L).coerceAtLeast(10))
                        if ((System.nanoTime() - moved.get()) / 1_000_000 >= stallMs) {
                            log("photos: thumbnail stream stalled")
                            stream.close()
                            return@launch
                        }
                    }
                }
                try {
                    val out = stream.output
                    for (id in ids) {
                        if (generation.get() != gen) throw IOException("superseded")
                        // A thumbnail that fails to load or encode is an empty record, not the end.
                        val jpeg = try {
                            library.thumbnail(id)
                        } catch (e: Exception) {
                            log("photos: thumbnail $id failed (${e.javaClass.simpleName})")
                            null
                        }
                        ThumbRecords.write(out, id, jpeg)
                        // Each record goes out as it is ready, so the Mac fills the grid as it goes.
                        out.flush()
                        moved.set(System.nanoTime())
                    }
                    ThumbRecords.end(out)
                    out.flush()
                } finally {
                    watchdog.cancel()
                }
            }
            log("photos: sent ${ids.size} thumbnails")
        } catch (e: IOException) {
            log("photos: thumbnail stream ended early (${e.javaClass.simpleName})")
        } finally {
            synchronized(lock) { if (current === stream) current = null }
            stream.close()
        }
    }

    /**
     * `photos.fetch`: the item goes as a `TRANSFER_KIND_PHOTO` offer carrying the request's ID, or
     * `files.failed {request_id, NOT_FOUND}` when it can't be read.
     */
    suspend fun onFetch(f: PhotoFetch) {
        val file = withContext(io) { library.file(f.id) }
        if (file == null) {
            val failed = TransferFailed.newBuilder()
                .setRequestId(f.requestId)
                .setReason(TransferError.TRANSFER_ERROR_NOT_FOUND)
                .build()
            send(MessageType.FILES_FAILED, failed)
            log("photos: fetch ${f.requestId} not found")
            return
        }
        val id = transfers.send(listOf(file), TransferKind.TRANSFER_KIND_PHOTO, f.requestId).single()
        onQueued(id, file)
        log("photos: fetch ${f.requestId} queued as $id")
    }

    /** Closes the thumbnail stream in progress, if any (the session ended, or the feature closed). */
    fun stop() {
        val stream = synchronized(lock) {
            generation.incrementAndGet()
            current.also { current = null }
        }
        stream?.close()
    }

    private fun MediaItem.toProto(): PhotoItem = PhotoItem.newBuilder()
        .setId(id)
        .setDateTakenMs(dateTakenMs)
        .setMime(mime)
        .setWidth(width.coerceAtLeast(0))
        .setHeight(height.coerceAtLeast(0))
        .setDurationMs(durationMs)
        .setVideo(video)
        .build()

    companion object {
        /** `photos.items` and `photos.thumbs` limits (Global Constraints). */
        const val MAX_ITEMS = 200
        const val MAX_IDS = 200
        /** No byte moved for this long ends a thumbnail stream (phone bulk sockets have no read timeout). */
        const val STALL_MS = 30_000L
    }
}
