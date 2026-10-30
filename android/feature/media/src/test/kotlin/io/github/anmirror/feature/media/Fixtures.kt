package io.github.anmirror.feature.media

import android.media.session.PlaybackState
import io.github.anmirror.protocol.v1.MediaCommand

/** Play, pause, next, previous and seek. */
const val ALL_ACTIONS = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
    PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_SEEK_TO

fun snapshot(
    key: String = "s1",
    title: String? = "Song",
    positionMs: Long = 10_000,
    playing: Boolean = true,
    speed: Float = 1f,
    durationMs: Long = 180_000,
    actions: Long = ALL_ACTIONS,
    remote: Boolean = false,
    volume: Int = 5,
    maxVolume: Int = 15,
    volumeFixed: Boolean = false,
    artworkJpeg: ByteArray? = null,
) = MediaSnapshot(
    key = key, appLabel = "Player", title = title, artist = "Artist", album = "Album",
    durationMs = durationMs, positionMs = positionMs, playing = playing, speed = speed, actions = actions,
    remote = remote, volume = volume, maxVolume = maxVolume, volumeFixed = volumeFixed, artworkJpeg = artworkJpeg,
)

class FakeSessions : MediaSessions {
    var current: MediaSnapshot? = null
    var applyResult = true
    var started = 0
    var stopped = 0
    val applied = mutableListOf<Pair<String, MediaCommand>>()
    private var onChange: (() -> Unit)? = null

    /** The callback given to the last [start], kept after [stop] (a late system callback). */
    var lastOnChange: (() -> Unit)? = null

    override fun start(onChange: () -> Unit) {
        started++
        this.onChange = onChange
        lastOnChange = onChange
    }

    override fun stop() {
        stopped++
        onChange = null
    }

    override fun snapshot(): MediaSnapshot? = current

    override fun apply(key: String, command: MediaCommand): Boolean {
        applied += key to command
        return applyResult
    }

    fun change(s: MediaSnapshot?) {
        current = s
        onChange?.invoke()
    }
}
