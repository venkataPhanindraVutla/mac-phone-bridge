// phone-sim's media session (F-07): one fake session "sim" that plays and pauses on media.command.
package io.github.anmirror.phonesim

import io.github.anmirror.connection.ControlChannel
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.FeatureAvailability
import io.github.anmirror.protocol.v1.MediaCommand
import io.github.anmirror.protocol.v1.MediaCommandKind
import io.github.anmirror.protocol.v1.MediaState

/**
 * After connect: `media.availability{enabled}` and the session's state. A `TOGGLE` for "sim"
 * flips `playing` and sends the new state at once. [onDone] is called after the second command.
 */
internal class SimMedia(
    private val channel: ControlChannel,
    private val emit: (String) -> Unit,
    private val onDone: () -> Unit,
) {
    private var playing = false
    private var commands = 0

    suspend fun start() {
        channel.send(Channel.CHANNEL_MEDIA, MessageType.MEDIA_AVAILABILITY, FeatureAvailability.newBuilder().setEnabled(true).build())
        sendState()
    }

    /** Takes `media.command`; false for any other message. */
    suspend fun onMessage(env: Envelope): Boolean {
        if (env.type != MessageType.MEDIA_COMMAND) return false
        val command = MediaCommand.parseFrom(env.payload)
        if (command.sessionKey == SESSION_KEY && command.kind == MediaCommandKind.MEDIA_COMMAND_KIND_TOGGLE) {
            playing = !playing
            sendState()
            emit("EVENT media-command kind=TOGGLE playing=$playing")
        }
        if (++commands == 2) onDone()
        return true
    }

    private suspend fun sendState() {
        val state = MediaState.newBuilder()
            .setActive(true)
            .setSessionKey(SESSION_KEY)
            .setTitle("Sim")
            .setPlaying(playing)
            .setSpeed(1f)
            .setCanPlay(true)
            .setCanPause(true)
            .build()
        channel.send(Channel.CHANNEL_MEDIA, MessageType.MEDIA_STATE, state)
    }

    private companion object {
        const val SESSION_KEY = "sim"
    }
}
