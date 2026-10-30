package io.github.anmirror.feature.media

/**
 * The picked session, read now. [positionMs] is the position at this moment (already
 * extrapolated while playing). [actions] holds `PlaybackState.ACTION_*` bits. The volume is the
 * session's own when [remote], else the phone's music stream. [artworkJpeg] is already fitted to
 * the wire limits ([ArtworkEncoder]), or null.
 */
data class MediaSnapshot(
    val key: String,
    val appLabel: String,
    val title: String?,
    val artist: String?,
    val album: String?,
    val durationMs: Long,
    val positionMs: Long,
    val playing: Boolean,
    val speed: Float,
    val actions: Long,
    val remote: Boolean,
    val volume: Int,
    val maxVolume: Int,
    val volumeFixed: Boolean,
    val artworkJpeg: ByteArray?,
)
