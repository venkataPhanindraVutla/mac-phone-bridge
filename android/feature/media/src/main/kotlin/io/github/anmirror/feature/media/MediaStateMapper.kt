package io.github.anmirror.feature.media

import android.media.session.PlaybackState
import io.github.anmirror.feature.notify.NotificationMapper
import io.github.anmirror.protocol.ArtworkKey
import io.github.anmirror.protocol.v1.MediaCommand
import io.github.anmirror.protocol.v1.MediaCommandKind
import io.github.anmirror.protocol.v1.MediaState
import io.github.anmirror.protocol.v1.MediaVolume

/** Pure rules: a session snapshot as `media.state`, and which commands that state offers (SPEC 20). */
object MediaStateMapper {
    /** Each of title, artist, album and app label (SPEC 10). */
    const val MAX_TEXT_BYTES = 256

    /** Null (nothing to report) is `active = false` with every other field empty. */
    fun toState(s: MediaSnapshot?): MediaState {
        if (s == null) return MediaState.newBuilder().setActive(false).build()
        val a = s.actions
        return MediaState.newBuilder()
            .setActive(true)
            .setSessionKey(s.key)
            .setAppLabel(cut(s.appLabel))
            .setTitle(cut(s.title))
            .setArtist(cut(s.artist))
            .setAlbum(cut(s.album))
            .setDurationMs(s.durationMs)
            .setPositionMs(s.positionMs)
            .setPlaying(s.playing)
            .setSpeed(s.speed)
            .setCanPlay(a.has(PlaybackState.ACTION_PLAY) || a.has(PlaybackState.ACTION_PLAY_PAUSE))
            .setCanPause(a.has(PlaybackState.ACTION_PAUSE) || a.has(PlaybackState.ACTION_PLAY_PAUSE))
            .setCanNext(a.has(PlaybackState.ACTION_SKIP_TO_NEXT))
            .setCanPrevious(a.has(PlaybackState.ACTION_SKIP_TO_PREVIOUS))
            .setCanSeek(a.has(PlaybackState.ACTION_SEEK_TO) && s.durationMs > 0)
            .setVolume(
                MediaVolume.newBuilder()
                    .setCurrent(s.volume.coerceAtLeast(0))
                    .setMax(s.maxVolume.coerceAtLeast(0))
                    .setFixed(s.volumeFixed),
            )
            .setArtworkKey(s.artworkJpeg?.let(ArtworkKey::of).orEmpty())
            .build()
    }

    /**
     * Whether [state] offers [command]'s action. A command it does not offer is ignored: `SEEK`
     * needs `can_seek`, `TOGGLE` needs pause while playing and play otherwise, `SET_VOLUME` needs a
     * volume that is not fixed.
     */
    fun offers(state: MediaState, command: MediaCommand): Boolean {
        if (!state.active) return false
        return when (command.kind) {
            MediaCommandKind.MEDIA_COMMAND_KIND_PLAY -> state.canPlay
            MediaCommandKind.MEDIA_COMMAND_KIND_PAUSE -> state.canPause
            MediaCommandKind.MEDIA_COMMAND_KIND_TOGGLE -> if (state.playing) state.canPause else state.canPlay
            MediaCommandKind.MEDIA_COMMAND_KIND_NEXT -> state.canNext
            MediaCommandKind.MEDIA_COMMAND_KIND_PREVIOUS -> state.canPrevious
            MediaCommandKind.MEDIA_COMMAND_KIND_SEEK -> state.canSeek
            MediaCommandKind.MEDIA_COMMAND_KIND_SET_VOLUME -> !state.volume.fixed
            else -> false
        }
    }

    /** `SET_VOLUME.volume` (a uint32) clamped to `0..volume.max`. */
    fun volumeLevel(state: MediaState, command: MediaCommand): Int =
        Integer.toUnsignedLong(command.volume).coerceAtMost(state.volume.max.toLong()).toInt()

    private fun Long.has(action: Long) = this and action != 0L

    private fun cut(s: String?): String = NotificationMapper.truncateUtf8(s.orEmpty(), MAX_TEXT_BYTES)
}
