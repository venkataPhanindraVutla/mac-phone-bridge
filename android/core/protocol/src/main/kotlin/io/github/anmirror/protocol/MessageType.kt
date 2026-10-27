package io.github.anmirror.protocol

/** Message type strings carried in `Envelope.type`. See protocol/SPEC.md section 3. */
object MessageType {
    const val HELLO = "system.hello"
    const val PING = "system.ping"
    const val PONG = "system.pong"
    const val ERROR = "system.error"
    const val GOODBYE = "system.goodbye"
    const val PAIR_REQUEST = "pairing.request"
    const val PAIR_VERIFIED = "pairing.verified"
    const val PAIR_CONFIRM = "pairing.confirm"
    const val PAIR_COMPLETE = "pairing.complete"
    const val STATUS_UPDATE = "status.update"
    const val FIND_RING = "find.ring"
    const val FIND_STOP = "find.stop"
    const val FIND_STATE = "find.state"

    val ALL: List<String> = listOf(
        HELLO, PING, PONG, ERROR, GOODBYE, PAIR_REQUEST, PAIR_VERIFIED, PAIR_CONFIRM,
        PAIR_COMPLETE, STATUS_UPDATE, FIND_RING, FIND_STOP, FIND_STATE,
    )
}
