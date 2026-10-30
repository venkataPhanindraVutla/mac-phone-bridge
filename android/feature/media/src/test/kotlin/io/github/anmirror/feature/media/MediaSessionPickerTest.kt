package io.github.anmirror.feature.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MediaSessionPickerTest {
    @Test fun playingSessionWinsOverRecent() {
        val recent = SessionInfo("recent", playing = false, lastPlayingAtMs = 9_000, order = 0)
        val playing = SessionInfo("playing", playing = true, lastPlayingAtMs = 1_000, order = 1)
        assertEquals("playing", MediaSessionPicker.pick(listOf(recent, playing))?.key)
    }

    @Test fun mostRecentPlayingWins() {
        val older = SessionInfo("older", playing = true, lastPlayingAtMs = 1_000, order = 0)
        val newer = SessionInfo("newer", playing = true, lastPlayingAtMs = 5_000, order = 1)
        val paused = SessionInfo("paused", playing = false, lastPlayingAtMs = 9_000, order = 2)
        assertEquals("newer", MediaSessionPicker.pick(listOf(older, newer, paused))?.key)
    }

    @Test fun noPlayingPicksMostRecentlyActive() {
        val a = SessionInfo("a", playing = false, lastPlayingAtMs = 9_000, order = 2)
        val b = SessionInfo("b", playing = false, lastPlayingAtMs = 0, order = 0)
        val c = SessionInfo("c", playing = false, lastPlayingAtMs = 5_000, order = 1)
        assertEquals("b", MediaSessionPicker.pick(listOf(a, b, c))?.key)
    }

    @Test fun emptyIsNull() {
        assertNull(MediaSessionPicker.pick(emptyList()))
    }
}
