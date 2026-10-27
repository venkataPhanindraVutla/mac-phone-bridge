package io.github.anmirror.connection

import com.google.protobuf.ByteString
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.PairingCrypto
import io.github.anmirror.protocol.PairingUri
import io.github.anmirror.protocol.ProtocolException
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.ErrorCode
import io.github.anmirror.protocol.v1.PairComplete
import io.github.anmirror.protocol.v1.PairConfirm
import io.github.anmirror.protocol.v1.PairRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.ChannelResult
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import javax.net.ssl.SSLException
import io.github.anmirror.protocol.v1.Error as ProtoError

sealed interface PairingResult {
    /** Paired. [channel] is still open: the caller sends `system.hello` next (SPEC 5.3 step 6). */
    data class Paired(val mac: PairedMac, val channel: ControlChannel) : PairingResult

    data class Failed(val reason: PairingFailure) : PairingResult
}

enum class PairingFailure {
    /** No host in the QR code gave a TLS 1.3 connection with the pinned Mac certificate. */
    UNREACHABLE,

    /**
     * `PAIRING_EXPIRED` (used, old, or 5-minute-old secret; too many bad proofs), or the
     * Mac refused our certificate at TLS because no pairing window is open.
     */
    EXPIRED,

    /** `BAD_PAIRING_SECRET`. */
    BAD_SECRET,

    /** Declined on either side, `PAIRING_REJECTED` or any other error, or the Mac hung up. */
    REJECTED,

    /** No `pairing.verified` within the verify timeout, or no user decision within 60 s. */
    TIMED_OUT,

    /** `PROTOCOL_MISMATCH`. */
    PROTOCOL_MISMATCH,
}

/**
 * The phone's side of pairing (SPEC 5.3), from a scanned QR code to `pairing.complete`.
 *
 * `showCode` shows the 6-digit confirmation code and returns the user's decision. It is
 * cancelled if the Mac declines (or hangs up) first, and given at most [confirmTimeoutMs].
 */
class PhonePairingClient(
    private val connector: MacConnector,
    private val identity: TlsIdentity,
    private val deviceName: String,
    private val deviceModel: String,
    private val verifyTimeoutMs: Long = 10_000,
    private val confirmTimeoutMs: Long = 60_000,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    suspend fun pair(uri: PairingUri, showCode: suspend (String) -> Boolean): PairingResult {
        val macFpHex = uri.macFingerprint.toHex()
        val channel = try {
            connector.connect(uri.hosts, uri.port, macFpHex)
        } catch (e: UnreachableException) {
            // A refusal at TLS by the pinned Mac means it has no pairing window open.
            return PairingResult.Failed(if (e.refusedByPeer) PairingFailure.EXPIRED else PairingFailure.UNREACHABLE)
        }
        val result = try {
            run(uri, macFpHex, channel, showCode)
        } catch (e: CancellationException) {
            channel.close()
            throw e
        } catch (e: IOException) {
            PairingResult.Failed(PairingFailure.REJECTED)
        } catch (e: ProtocolException) {
            PairingResult.Failed(PairingFailure.REJECTED)
        }
        if (result is PairingResult.Failed) channel.close()
        return result
    }

    /** Ends pairing with [reason]; caught in [pair]. */
    private class Abort(val reason: PairingFailure) : Exception(reason.name, null, false, false)

    private suspend fun run(
        uri: PairingUri,
        macFpHex: String,
        channel: ControlChannel,
        showCode: suspend (String) -> Boolean,
    ): PairingResult = try {
        steps(uri, macFpHex, channel, showCode)
    } catch (a: Abort) {
        fail(a.reason)
    }

    private suspend fun steps(
        uri: PairingUri,
        macFpHex: String,
        channel: ControlChannel,
        showCode: suspend (String) -> Boolean,
    ): PairingResult {
        val phoneFp = PairingCrypto.fingerprint(identity.certificateDer)

        // Step 1: prove we scanned this Mac's QR code.
        val request = PairRequest.newBuilder()
            .setProtocolVersion(PROTOCOL_VERSION)
            .setSecretProof(ByteString.copyFrom(PairingCrypto.secretProof(uri.secret, uri.macFingerprint, phoneFp)))
            .setDeviceName(deviceName)
            .setDeviceModel(deviceModel)
            .build()
        try {
            try {
                channel.send(Channel.CHANNEL_PAIRING, MessageType.PAIR_REQUEST, request)
            } catch (e: IOException) {
                // The write failed (broken pipe): the reader may hold the reason, e.g. a TLS alert.
                throw channel.closeCause() as? SSLException ?: e
            }

            // Step 2: pairing.verified (or an error).
            withTimeoutOrNull(verifyTimeoutMs) {
                while (true) {
                    val env = channel.receive() ?: throw Abort(PairingFailure.REJECTED)
                    when (env.type) {
                        MessageType.PAIR_VERIFIED -> break
                        MessageType.ERROR -> throw Abort(errorFailure(env))
                        else -> Unit
                    }
                }
            } ?: throw Abort(PairingFailure.TIMED_OUT)
        } catch (e: SSLException) {
            // TLS 1.3: a Mac without an open pairing window refuses our certificate after the
            // handshake, so we may only see its alert now. Its window is closed: expired.
            throw Abort(PairingFailure.EXPIRED)
        }

        // Steps 3 and 4: both users compare the code. The Mac's decision may come before ours;
        // a decline (or hang-up) from the Mac ends our wait.
        val code = PairingCrypto.confirmationCode(uri.macFingerprint, phoneFp)
        val decision: Boolean? = coroutineScope {
            val user = async { withTimeoutOrNull(confirmTimeoutMs) { showCode(code) } }
            try {
                var decided = false
                var answer: Boolean? = null
                while (!decided) {
                    select<Unit> {
                        user.onAwait {
                            answer = it
                            decided = true
                        }
                        channel.onReceiveCatching { result ->
                            val env = envelopeOrThrow(result)
                            when (env.type) {
                                MessageType.PAIR_CONFIRM -> if (!accepted(env)) throw Abort(PairingFailure.REJECTED)
                                MessageType.ERROR -> throw Abort(errorFailure(env))
                                else -> Unit
                            }
                        }
                    }
                }
                answer
            } finally {
                user.cancel()
            }
        }
        channel.send(Channel.CHANNEL_PAIRING, MessageType.PAIR_CONFIRM, confirm(decision == true))
        when (decision) {
            null -> throw Abort(PairingFailure.TIMED_OUT)
            false -> throw Abort(PairingFailure.REJECTED)
            true -> Unit
        }

        // Step 5: pairing.complete, once the Mac's user has accepted too.
        val complete = withTimeoutOrNull(confirmTimeoutMs) {
            var complete: PairComplete? = null
            while (complete == null) {
                val env = channel.receive() ?: throw Abort(PairingFailure.REJECTED)
                when (env.type) {
                    MessageType.PAIR_CONFIRM -> if (!accepted(env)) throw Abort(PairingFailure.REJECTED)
                    MessageType.PAIR_COMPLETE ->
                        complete = parseOrNull { PairComplete.parseFrom(env.payload) } ?: throw Abort(PairingFailure.REJECTED)
                    MessageType.ERROR -> throw Abort(errorFailure(env))
                    else -> Unit
                }
            }
            complete
        } ?: throw Abort(PairingFailure.TIMED_OUT)
        if (complete.discoveryKey.size() != 32) throw Abort(PairingFailure.REJECTED)

        val mac = PairedMac(
            id = macFpHex,
            name = complete.macName.ifEmpty { uri.macName },
            fingerprintHex = macFpHex,
            discoveryKey = complete.discoveryKey.toByteArray(),
            lastHost = channel.host,
            lastPort = channel.port,
            lastConnectedAt = clock(),
        )
        return PairingResult.Paired(mac, channel)
    }

    /** The envelope, or the channel's close cause, or [Abort] (REJECTED) on a clean close. */
    private fun envelopeOrThrow(result: ChannelResult<Envelope>): Envelope {
        result.getOrNull()?.let { return it }
        result.exceptionOrNull()?.let { throw it }
        throw Abort(PairingFailure.REJECTED)
    }

    private fun fail(reason: PairingFailure) = PairingResult.Failed(reason)

    private fun confirm(accepted: Boolean) = PairConfirm.newBuilder().setAccepted(accepted).build()

    private fun accepted(env: Envelope): Boolean = parseOrNull { PairConfirm.parseFrom(env.payload) }?.accepted ?: false

    private fun errorFailure(env: Envelope): PairingFailure =
        when (parseOrNull { ProtoError.parseFrom(env.payload) }?.code) {
            ErrorCode.ERROR_CODE_PAIRING_EXPIRED -> PairingFailure.EXPIRED
            ErrorCode.ERROR_CODE_BAD_PAIRING_SECRET -> PairingFailure.BAD_SECRET
            ErrorCode.ERROR_CODE_PROTOCOL_MISMATCH -> PairingFailure.PROTOCOL_MISMATCH
            else -> PairingFailure.REJECTED
        }
}
