package io.github.anmirror.feature.media

import com.google.protobuf.ByteString
import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.MediaArtwork
import io.github.anmirror.protocol.v1.MediaCommand
import io.github.anmirror.protocol.v1.MediaState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * Phone side of `media.*` (SPEC 20) while the feature is open: [onConnected] to [onDisconnected].
 * Every session change is read again ([MediaSessions.snapshot]); artwork goes first whenever its key
 * is not among the [ARTWORK_KEYS] most recently sent this connection (the Mac keeps that many; ruling
 * R36), then the state goes through the [StateThrottle]. A state that differs from
 * the last one only by where playback has got to is not sent: the Mac extrapolates that itself.
 * Logs command kinds only, never what is playing.
 */
class MediaBridge(
    private val sessions: MediaSessions,
    private val send: suspend (String, MessageLite) -> Boolean,
    private val scope: CoroutineScope,
    private val clock: () -> Long,
    private val log: (String) -> Unit = {},
) {
    private val throttle = StateThrottle(scope, clock = clock) { send(MessageType.MEDIA_STATE, it) }

    /** One look at the sessions at a time, so artwork and states leave in order. */
    private val looking = Mutex()
    private val lookQueued = AtomicBoolean(false)

    // Guarded by [lock].
    private val lock = Any()
    private var open = false
    private var generation = 0
    /** The keys sent this connection, eldest first, at most [ARTWORK_KEYS]; a hit does not refresh. */
    private val sentArtwork = LinkedHashSet<String>()
    private var lastOffered: MediaState? = null
    private var lastOfferedAt = 0L

    /** Starts watching the sessions and sends the current state at once (artwork first). */
    suspend fun onConnected() {
        synchronized(lock) {
            open = true
            generation++
            sentArtwork.clear()
            lastOffered = null
        }
        throttle.reset()
        sessions.start(::onChange)
        look()
    }

    /** A session changed: look again (looks asked for while one is queued are merged). */
    private fun onChange() {
        if (!lookQueued.compareAndSet(false, true)) return
        scope.launch {
            lookQueued.set(false)
            try {
                look()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("look failed (${e.javaClass.simpleName})") // the class only: a message could name the track
            }
        }
    }

    /** Hands [c] to the sessions; the state it changes goes out through their callbacks. */
    fun onCommand(c: MediaCommand) {
        val applied = sessions.apply(c.sessionKey, c)
        log(if (applied) "command ${c.kind}" else "command ${c.kind} ignored")
    }

    /** Stops watching; forgets which artwork the Mac has and what it was last sent. */
    fun onDisconnected() {
        synchronized(lock) {
            open = false
            generation++
            sentArtwork.clear()
            lastOffered = null
        }
        sessions.stop()
        throttle.reset()
    }

    private suspend fun look(): Unit = looking.withLock {
        val gen = synchronized(lock) { if (open) generation else return@withLock }
        val snapshot = sessions.snapshot()
        val state = MediaStateMapper.toState(snapshot)
        val jpeg = snapshot?.artworkJpeg
        val key = state.artworkKey
        val newArtwork = synchronized(lock) {
            if (gen != generation) return@withLock
            key.isNotEmpty() && key !in sentArtwork
        }
        if (newArtwork && jpeg != null) {
            val artwork = MediaArtwork.newBuilder().setArtworkKey(key).setJpeg(ByteString.copyFrom(jpeg)).build()
            if (send(MessageType.MEDIA_ARTWORK, artwork)) synchronized(lock) { if (gen == generation) remember(key) }
        }
        val now = clock()
        synchronized(lock) {
            if (gen != generation || !worthOffering(state, now)) return@withLock
            lastOffered = state
            lastOfferedAt = now
        }
        throttle.offer(state)
    }

    /** Under [lock]: [key] as the newest sent, the eldest dropped past [ARTWORK_KEYS], as the Mac's cache does. */
    private fun remember(key: String) {
        sentArtwork += key
        while (sentArtwork.size > ARTWORK_KEYS) sentArtwork.remove(sentArtwork.first())
    }

    /**
     * Anything but the position changed, or the position jumped (a seek): more than [SEEK_JUMP_MS]
     * away from the last offered position carried forward to [now] at its speed.
     */
    private fun worthOffering(state: MediaState, now: Long): Boolean {
        val last = lastOffered ?: return true
        if (state.toBuilder().clearPositionMs().build() != last.toBuilder().clearPositionMs().build()) return true
        val speed = if (last.speed == 0f) 1f else last.speed
        val expected = if (last.playing) last.positionMs + ((now - lastOfferedAt) * speed).toLong() else last.positionMs
        return abs(state.positionMs - expected) > SEEK_JUMP_MS
    }

    private companion object {
        const val SEEK_JUMP_MS = 2_000L
        /** SPEC 20: the Mac keeps the 8 most recently sent artworks. */
        const val ARTWORK_KEYS = 8
    }
}
