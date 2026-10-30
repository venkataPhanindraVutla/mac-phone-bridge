package io.github.anmirror.feature.media

import java.util.concurrent.atomic.AtomicLong

/**
 * One session's encoded artwork, encoded again only after its metadata changed. Take a
 * [ticket] before reading the metadata and pass it to [get]: a change ([invalidate]) that lands
 * during the read moves the counter past the ticket, so the next look encodes the new picture.
 */
internal class ArtworkSlot {
    private val changes = AtomicLong(1) // starts changed: nothing encoded yet
    private var encodedAt = 0L // guarded by this
    private var jpeg: ByteArray? = null // guarded by this

    fun invalidate() {
        changes.incrementAndGet()
    }

    fun ticket(): Long = changes.get()

    /** The picture encoded for [ticket], from [encode] unless that ticket's was already made. */
    fun get(ticket: Long, encode: () -> ByteArray?): ByteArray? {
        synchronized(this) { if (encodedAt == ticket) return jpeg }
        val fresh = encode()
        synchronized(this) {
            jpeg = fresh
            encodedAt = ticket
        }
        return fresh
    }
}
