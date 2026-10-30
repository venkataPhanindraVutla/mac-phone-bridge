package io.github.anmirror.feature.media

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.ArtworkKey
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.MediaArtwork
import io.github.anmirror.protocol.v1.MediaCommand
import io.github.anmirror.protocol.v1.MediaCommandKind
import io.github.anmirror.protocol.v1.MediaState
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class MediaBridgeTest {
    private val sessions = FakeSessions()
    private val sent = mutableListOf<Pair<String, MessageLite>>()
    private val send: suspend (String, MessageLite) -> Boolean = { type, m ->
        sent += type to m
        true
    }

    private fun TestScope.bridge() = MediaBridge(sessions, send, this, clock = { currentTime })

    private fun states() = sent.filter { it.first == MessageType.MEDIA_STATE }.map { it.second as MediaState }
    private fun artworks() = sent.filter { it.first == MessageType.MEDIA_ARTWORK }.map { it.second as MediaArtwork }

    @Test fun connectSendsStateAtOnce() = runTest {
        sessions.current = snapshot()
        bridge().onConnected()
        assertEquals(1, sessions.started)
        assertEquals(listOf(MessageType.MEDIA_STATE), sent.map { it.first })
        assertEquals("Song", states().single().title)
        assertTrue(states().single().active)
    }

    @Test fun connectWithNothingPlayingSendsInactive() = runTest {
        bridge().onConnected()
        assertFalse(states().single().active)
    }

    @Test fun artworkIsSentBeforeStateAndOnlyOnce() = runTest {
        val jpeg = byteArrayOf(9, 8, 7)
        val key = ArtworkKey.of(jpeg)
        sessions.current = snapshot(artworkJpeg = jpeg)
        bridge().onConnected()
        assertEquals(listOf(MessageType.MEDIA_ARTWORK, MessageType.MEDIA_STATE), sent.map { it.first })
        assertEquals(key, artworks().single().artworkKey)
        assertEquals(jpeg.toList(), artworks().single().jpeg.toByteArray().toList())
        assertEquals(key, states().single().artworkKey)

        advanceTimeBy(1_000)
        sessions.change(snapshot(title = "Next song", artworkJpeg = jpeg.copyOf()))
        advanceUntilIdle()
        assertEquals(1, artworks().size)
        assertEquals(listOf("Song", "Next song"), states().map { it.title })

        // A new picture goes first again.
        advanceTimeBy(1_000)
        val other = byteArrayOf(1)
        sessions.change(snapshot(title = "Third", artworkJpeg = other))
        advanceUntilIdle()
        assertEquals(MessageType.MEDIA_ARTWORK, sent[sent.size - 2].first)
        assertEquals(ArtworkKey.of(other), states().last().artworkKey)
    }

    @Test fun sessionGoneSendsInactive() = runTest {
        sessions.current = snapshot()
        bridge().onConnected()
        advanceTimeBy(1_000)
        sessions.change(null)
        advanceUntilIdle()
        assertEquals(listOf(true, false), states().map { it.active })
        assertEquals(MediaState.newBuilder().setActive(false).build(), states().last())
    }

    @Test fun staleSessionCommandIsIgnored() = runTest {
        sessions.current = snapshot(key = "now")
        val bridge = bridge()
        bridge.onConnected()
        sent.clear()
        sessions.applyResult = false
        val command = MediaCommand.newBuilder().setSessionKey("old").setKind(MediaCommandKind.MEDIA_COMMAND_KIND_TOGGLE).build()
        bridge.onCommand(command)
        advanceUntilIdle()
        assertEquals(listOf("old" to command), sessions.applied)
        assertTrue(sent.isEmpty())
    }

    @Test fun positionOnlyChangeIsNotSent() = runTest {
        sessions.current = snapshot(positionMs = 10_000, playing = true, speed = 1f)
        bridge().onConnected()
        advanceTimeBy(5_000)
        // Where the Mac's own extrapolation puts it (within 2 s): not sent.
        sessions.change(snapshot(positionMs = 16_500, playing = true, speed = 1f))
        advanceUntilIdle()
        assertEquals(1, states().size)
    }

    @Test fun pausedPositionOnlyChangeIsNotSent() = runTest {
        sessions.current = snapshot(positionMs = 10_000, playing = false)
        bridge().onConnected()
        advanceTimeBy(5_000)
        sessions.change(snapshot(positionMs = 11_000, playing = false))
        advanceUntilIdle()
        assertEquals(1, states().size)
    }

    @Test fun seekIsSent() = runTest {
        sessions.current = snapshot(positionMs = 10_000, playing = true, speed = 1f)
        bridge().onConnected()
        advanceTimeBy(5_000)
        sessions.change(snapshot(positionMs = 60_000, playing = true, speed = 1f))
        advanceUntilIdle()
        assertEquals(listOf(10_000L, 60_000L), states().map { it.positionMs })
    }

    @Test fun disconnectForgetsArtworkKeys() = runTest {
        val jpeg = byteArrayOf(4, 5, 6)
        sessions.current = snapshot(artworkJpeg = jpeg)
        val bridge = bridge()
        bridge.onConnected()
        bridge.onDisconnected()
        assertEquals(1, sessions.stopped)
        bridge.onConnected()
        assertEquals(
            listOf(MessageType.MEDIA_ARTWORK, MessageType.MEDIA_STATE, MessageType.MEDIA_ARTWORK, MessageType.MEDIA_STATE),
            sent.map { it.first },
        )
        assertIs<MediaArtwork>(sent[2].second)
    }

    @Test fun changesAfterDisconnectAreNotSent() = runTest {
        sessions.current = snapshot()
        val bridge = bridge()
        bridge.onConnected()
        val late = sessions.lastOnChange!!
        bridge.onDisconnected()
        sent.clear()
        // A system callback already on its way when the bridge stopped.
        sessions.current = snapshot(title = "Other")
        late()
        advanceUntilIdle()
        assertTrue(sent.isEmpty())
    }

    @Test fun commandGoesToTheSessions() = runTest {
        sessions.current = snapshot()
        val bridge = bridge()
        bridge.onConnected()
        val command = MediaCommand.newBuilder().setSessionKey("s1").setKind(MediaCommandKind.MEDIA_COMMAND_KIND_NEXT).build()
        bridge.onCommand(command)
        assertEquals(listOf("s1" to command), sessions.applied)
    }
}
