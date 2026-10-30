package io.github.anmirror.feature.media

import android.media.session.PlaybackState
import io.github.anmirror.protocol.ArtworkKey
import io.github.anmirror.protocol.v1.MediaCommand
import io.github.anmirror.protocol.v1.MediaCommandKind
import io.github.anmirror.protocol.v1.MediaState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MediaStateMapperTest {
    @Test fun nullIsInactive() {
        assertEquals(MediaState.newBuilder().setActive(false).build(), MediaStateMapper.toState(null))
    }

    @Test fun mapsTheSnapshot() {
        val jpeg = byteArrayOf(1, 2, 3)
        val s = MediaStateMapper.toState(snapshot(artworkJpeg = jpeg))
        assertTrue(s.active)
        assertEquals("s1", s.sessionKey)
        assertEquals("Player", s.appLabel)
        assertEquals("Song", s.title)
        assertEquals("Artist", s.artist)
        assertEquals("Album", s.album)
        assertEquals(180_000, s.durationMs)
        assertEquals(10_000, s.positionMs)
        assertTrue(s.playing)
        assertEquals(1f, s.speed)
        assertTrue(s.canPlay && s.canPause && s.canNext && s.canPrevious && s.canSeek)
        assertEquals(ArtworkKey.of(jpeg), s.artworkKey)
        assertEquals("", MediaStateMapper.toState(snapshot(artworkJpeg = null)).artworkKey)
    }

    @Test fun playPauseCoversBoth() {
        val s = MediaStateMapper.toState(snapshot(actions = PlaybackState.ACTION_PLAY_PAUSE))
        assertTrue(s.canPlay)
        assertTrue(s.canPause)
        assertFalse(s.canNext || s.canPrevious || s.canSeek)
    }

    @Test fun liveStreamHasNoSeek() {
        val s = MediaStateMapper.toState(snapshot(durationMs = 0, actions = PlaybackState.ACTION_SEEK_TO))
        assertFalse(s.canSeek)
    }

    @Test fun textsAreCutTo256Bytes() {
        val long = "é".repeat(300) // 600 bytes
        val s = MediaStateMapper.toState(
            snapshot(title = long).copy(appLabel = long, artist = long, album = long),
        )
        for (text in listOf(s.title, s.appLabel, s.artist, s.album)) {
            assertTrue(text.toByteArray(Charsets.UTF_8).size <= 256)
            assertTrue(text.endsWith("…"))
        }
        assertEquals("", MediaStateMapper.toState(snapshot(title = null)).title)
    }

    @Test fun remoteSessionUsesPlaybackInfoVolume() {
        val s = MediaStateMapper.toState(snapshot(remote = true, volume = 7, maxVolume = 20))
        assertEquals(7, s.volume.current)
        assertEquals(20, s.volume.max)
        assertFalse(s.volume.fixed)
    }

    @Test fun fixedVolumeIsReported() {
        assertTrue(MediaStateMapper.toState(snapshot(volumeFixed = true)).volume.fixed)
    }

    @Test fun onlyOfferedCommandsAreAllowed() {
        fun cmd(kind: MediaCommandKind) = MediaCommand.newBuilder().setSessionKey("s1").setKind(kind).build()
        val all = MediaStateMapper.toState(snapshot())
        for (kind in MediaCommandKind.entries.filter { it != MediaCommandKind.UNRECOGNIZED && it != MediaCommandKind.MEDIA_COMMAND_KIND_UNSPECIFIED }) {
            assertTrue(MediaStateMapper.offers(all, cmd(kind)), kind.name)
        }
        assertFalse(MediaStateMapper.offers(all, cmd(MediaCommandKind.MEDIA_COMMAND_KIND_UNSPECIFIED)))
        val live = MediaStateMapper.toState(snapshot(durationMs = 0))
        assertFalse(MediaStateMapper.offers(live, cmd(MediaCommandKind.MEDIA_COMMAND_KIND_SEEK)))
        val fixed = MediaStateMapper.toState(snapshot(volumeFixed = true))
        assertFalse(MediaStateMapper.offers(fixed, cmd(MediaCommandKind.MEDIA_COMMAND_KIND_SET_VOLUME)))
        // TOGGLE needs pause while playing, play while paused.
        val playOnly = MediaStateMapper.toState(snapshot(actions = PlaybackState.ACTION_PLAY))
        assertFalse(MediaStateMapper.offers(playOnly, cmd(MediaCommandKind.MEDIA_COMMAND_KIND_TOGGLE)))
        assertTrue(MediaStateMapper.offers(playOnly.toBuilder().setPlaying(false).build(), cmd(MediaCommandKind.MEDIA_COMMAND_KIND_TOGGLE)))
        assertFalse(MediaStateMapper.offers(MediaStateMapper.toState(null), cmd(MediaCommandKind.MEDIA_COMMAND_KIND_PLAY)))
    }

    @Test fun volumeIsClampedToMax() {
        val state = MediaStateMapper.toState(snapshot(maxVolume = 15))
        assertEquals(15, MediaStateMapper.volumeLevel(state, MediaCommand.newBuilder().setVolume(40).build()))
        assertEquals(15, MediaStateMapper.volumeLevel(state, MediaCommand.newBuilder().setVolume(-1).build())) // uint32 max
        assertEquals(3, MediaStateMapper.volumeLevel(state, MediaCommand.newBuilder().setVolume(3).build()))
    }
}
