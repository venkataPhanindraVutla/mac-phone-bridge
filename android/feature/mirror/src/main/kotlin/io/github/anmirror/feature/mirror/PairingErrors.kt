package io.github.anmirror.feature.mirror

import io.github.anmirror.adb.AdbPairingException
import java.io.InterruptedIOException
import java.util.concurrent.TimeoutException

/** Why pairing failed, as the Full mode screen and the pairing notification word it. */
enum class PairingError { WRONG_PORT, WRONG_CODE, NOT_LISTENING, INVALID, TIMEOUT }

object PairingErrors {
    /**
     * [port] is the pairing port that was tried; [knownConnectPort] the port Wireless debugging
     * connects on, if known (typing that one is the commonest mistake). A timeout anywhere in the
     * chain is TIMEOUT; a stage comes from [AdbPairingException]; anything else reads as nothing
     * listening (the pairing screen closed).
     */
    fun classify(e: Throwable, port: Int, knownConnectPort: Int?): PairingError {
        if (knownConnectPort != null && port == knownConnectPort) return PairingError.WRONG_PORT
        val chain = generateSequence(e) { it.cause }.take(MAX_CAUSES).toList()
        // SocketTimeoutException is an InterruptedIOException.
        if (chain.any { it is InterruptedIOException || it is TimeoutException }) return PairingError.TIMEOUT
        return when ((e as? AdbPairingException)?.stage) {
            AdbPairingException.Stage.NOT_LISTENING -> PairingError.NOT_LISTENING
            AdbPairingException.Stage.HANDSHAKE -> PairingError.WRONG_PORT
            AdbPairingException.Stage.AFTER_HANDSHAKE -> PairingError.WRONG_CODE
            // A refused connection, or a failure that names no stage: try again with the screen open.
            null -> PairingError.NOT_LISTENING
        }
    }

    private const val MAX_CAUSES = 16
}
