package io.github.anmirror.feature.media

import android.content.ComponentName
import android.content.Context
import android.database.ContentObserver
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import androidx.core.content.getSystemService
import io.github.anmirror.protocol.v1.MediaCommand
import io.github.anmirror.protocol.v1.MediaCommandKind
import java.util.UUID

/** The phone's media sessions, as the [MediaBridge] needs them. */
interface MediaSessions {
    /** Starts watching; [onChange] is called (on any thread) whenever what [snapshot] reads may have changed. */
    fun start(onChange: () -> Unit)

    fun stop()

    /** The picked session, now; null when there is none or it can't be read (no notification access). */
    fun snapshot(): MediaSnapshot?

    /** Applies [command] to the picked session; false when [key] is not its key or it does not offer the action. */
    fun apply(key: String, command: MediaCommand): Boolean
}

/**
 * [MediaSessions] through [MediaSessionManager], which lets a notification listener ([listener])
 * see other apps' sessions. Without notification access there are none. Each session gets a
 * random key for as long as it stays active. Callbacks arrive on the main thread; reads may
 * happen on any thread.
 */
class AndroidMediaSessions(
    context: Context,
    private val listener: ComponentName,
    private val clock: () -> Long = SystemClock::elapsedRealtime,
) : MediaSessions {
    private val app = context.applicationContext
    private val manager: MediaSessionManager? = app.getSystemService()
    private val audio: AudioManager? = app.getSystemService()
    private val handler = Handler(Looper.getMainLooper())

    private val lock = Any()

    // Guarded by [lock]. [sessions] is in the system's order: most recently active first.
    private var sessions: List<Tracked> = emptyList()
    private var onChange: (() -> Unit)? = null
    private var watching = false

    private val activeListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        update(controllers.orEmpty())
    }

    // The local volume lives in Settings.System.
    private val volumeObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) {
            changed()
        }
    }

    private inner class Tracked(val controller: MediaController) {
        val token: MediaSession.Token = controller.sessionToken
        val key: String = UUID.randomUUID().toString()

        @Volatile var lastPlayingAtMs = 0L
        @Volatile private var wasPlaying = false
        @Volatile var artworkStale = true
        @Volatile var artwork: ByteArray? = null

        val callback = object : MediaController.Callback() {
            override fun onPlaybackStateChanged(state: PlaybackState?) {
                notePlaying(state)
                changed()
            }

            override fun onMetadataChanged(metadata: MediaMetadata?) {
                artworkStale = true
                changed()
            }

            override fun onAudioInfoChanged(info: MediaController.PlaybackInfo) {
                changed()
            }

            override fun onSessionDestroyed() {
                forget(this@Tracked)
            }
        }

        /** [lastPlayingAtMs] is when the state last became `STATE_PLAYING`. */
        fun notePlaying(state: PlaybackState?) {
            val playing = state?.state == PlaybackState.STATE_PLAYING
            if (playing && !wasPlaying) lastPlayingAtMs = clock()
            wasPlaying = playing
        }

        fun isPlaying() = controller.playbackState?.state == PlaybackState.STATE_PLAYING
    }

    override fun start(onChange: () -> Unit) {
        val controllers = synchronized(lock) {
            this.onChange = onChange
            if (watching) return
            val manager = manager ?: return
            try {
                manager.addOnActiveSessionsChangedListener(activeListener, listener, handler)
                watching = true
                manager.getActiveSessions(listener)
            } catch (e: SecurityException) { // no notification access
                if (watching) manager.removeOnActiveSessionsChangedListener(activeListener)
                watching = false
                return
            }
        }
        app.contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, volumeObserver)
        update(controllers)
    }

    override fun stop() {
        val gone = synchronized(lock) {
            onChange = null
            if (!watching) return
            watching = false
            sessions.also { sessions = emptyList() }
        }
        manager?.removeOnActiveSessionsChangedListener(activeListener)
        app.contentResolver.unregisterContentObserver(volumeObserver)
        gone.forEach { it.controller.unregisterCallback(it.callback) }
    }

    /** Keeps a [Tracked] (and so its key) for every session still active, in the system's order. */
    private fun update(controllers: List<MediaController>) {
        val added = mutableListOf<Tracked>()
        val removed: List<Tracked>
        synchronized(lock) {
            if (!watching) return
            val known = sessions.associateBy { it.token }
            val next = controllers.map { c -> known[c.sessionToken] ?: Tracked(c).also { added += it } }
            val keep = next.map { it.token }.toSet()
            removed = sessions.filter { it.token !in keep }
            sessions = next
        }
        removed.forEach { it.controller.unregisterCallback(it.callback) }
        for (t in added) {
            t.notePlaying(t.controller.playbackState)
            t.controller.registerCallback(t.callback, handler)
            // Stopped (or the session gone) meanwhile: nothing would unregister it later.
            if (!synchronized(lock) { watching && t in sessions }) t.controller.unregisterCallback(t.callback)
        }
        changed()
    }

    private fun forget(t: Tracked) {
        synchronized(lock) { sessions = sessions - t }
        t.controller.unregisterCallback(t.callback)
        changed()
    }

    private fun changed() {
        synchronized(lock) { onChange }?.invoke()
    }

    private fun picked(): Tracked? {
        val list = synchronized(lock) { sessions }
        val infos = list.mapIndexed { i, t -> SessionInfo(t.key, t.isPlaying(), t.lastPlayingAtMs, i) }
        val key = MediaSessionPicker.pick(infos)?.key ?: return null
        return list.firstOrNull { it.key == key }
    }

    override fun snapshot(): MediaSnapshot? = try {
        picked()?.let { read(it, withArtwork = true) }
    } catch (e: SecurityException) {
        null
    } catch (e: IllegalStateException) { // the session went away mid-read
        null
    }

    private fun read(t: Tracked, withArtwork: Boolean): MediaSnapshot {
        val c = t.controller
        val state = c.playbackState
        val metadata = c.metadata
        val playing = state?.state == PlaybackState.STATE_PLAYING
        val durationMs = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION)?.coerceAtLeast(0) ?: 0
        val volume = volumeOf(c)
        return MediaSnapshot(
            key = t.key,
            appLabel = appLabel(c.packageName),
            title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)
                ?: metadata?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE),
            artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST)
                ?: metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST),
            album = metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM),
            durationMs = durationMs,
            positionMs = positionOf(state, playing, durationMs),
            playing = playing,
            speed = state?.playbackSpeed ?: 0f,
            actions = state?.actions ?: 0L,
            remote = volume.remote,
            volume = volume.current,
            maxVolume = volume.max,
            volumeFixed = volume.fixed,
            artworkJpeg = if (withArtwork) artworkOf(t, metadata) else null,
        )
    }

    /** `position + (now - lastPositionUpdateTime) * speed` while playing, kept within `0..duration`. */
    private fun positionOf(state: PlaybackState?, playing: Boolean, durationMs: Long): Long {
        if (state == null || state.position < 0) return 0
        var position = state.position
        if (playing && state.lastPositionUpdateTime > 0) {
            position += ((clock() - state.lastPositionUpdateTime) * state.playbackSpeed).toLong()
        }
        position = position.coerceAtLeast(0)
        return if (durationMs > 0) position.coerceAtMost(durationMs) else position
    }

    private class Volume(val remote: Boolean, val current: Int, val max: Int, val fixed: Boolean)

    /** A remote session's own volume; otherwise the music stream's. */
    private fun volumeOf(c: MediaController): Volume {
        val info: MediaController.PlaybackInfo? = c.playbackInfo
        if (info != null && info.playbackType == MediaController.PlaybackInfo.PLAYBACK_TYPE_REMOTE) {
            return Volume(
                remote = true,
                current = info.currentVolume,
                max = info.maxVolume,
                fixed = info.volumeControl == VolumeProvider.VOLUME_CONTROL_FIXED,
            )
        }
        val a = audio ?: return Volume(remote = false, current = 0, max = 0, fixed = true)
        return Volume(
            remote = false,
            current = a.getStreamVolume(AudioManager.STREAM_MUSIC),
            max = a.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            fixed = a.isVolumeFixed,
        )
    }

    /** Encoded again only after the metadata changed: ART, else ALBUM_ART, else DISPLAY_ICON. */
    private fun artworkOf(t: Tracked, metadata: MediaMetadata?): ByteArray? {
        if (!t.artworkStale) return t.artwork
        t.artworkStale = false
        val bitmap: Bitmap? = metadata?.let {
            it.getBitmap(MediaMetadata.METADATA_KEY_ART)
                ?: it.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
                ?: it.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
        }
        val jpeg = bitmap?.let(ArtworkEncoder::encode)
        t.artwork = jpeg
        return jpeg
    }

    private fun appLabel(packageName: String): String = try {
        val pm = app.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    } catch (e: Exception) {
        packageName
    }

    override fun apply(key: String, command: MediaCommand): Boolean {
        val t = picked() ?: return false
        if (t.key != key) return false
        return try {
            val snapshot = read(t, withArtwork = false)
            val state = MediaStateMapper.toState(snapshot)
            if (!MediaStateMapper.offers(state, command)) return false
            val controls = t.controller.transportControls
            when (command.kind) {
                MediaCommandKind.MEDIA_COMMAND_KIND_PLAY -> controls.play()
                MediaCommandKind.MEDIA_COMMAND_KIND_PAUSE -> controls.pause()
                MediaCommandKind.MEDIA_COMMAND_KIND_TOGGLE -> if (state.playing) controls.pause() else controls.play()
                MediaCommandKind.MEDIA_COMMAND_KIND_NEXT -> controls.skipToNext()
                MediaCommandKind.MEDIA_COMMAND_KIND_PREVIOUS -> controls.skipToPrevious()
                MediaCommandKind.MEDIA_COMMAND_KIND_SEEK -> controls.seekTo(command.positionMs.coerceIn(0, state.durationMs))
                MediaCommandKind.MEDIA_COMMAND_KIND_SET_VOLUME -> {
                    val level = MediaStateMapper.volumeLevel(state, command)
                    if (snapshot.remote) {
                        t.controller.setVolumeTo(level, 0)
                    } else {
                        val a = audio ?: return false
                        a.setStreamVolume(AudioManager.STREAM_MUSIC, level, 0)
                    }
                }
                else -> return false
            }
            true
        } catch (e: SecurityException) { // e.g. a volume change Do Not Disturb refuses
            false
        } catch (e: IllegalStateException) { // the session went away
            false
        }
    }
}
