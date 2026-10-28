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
    const val NOTIFY_POSTED = "notify.posted"
    const val NOTIFY_REMOVED = "notify.removed"
    const val NOTIFY_SNAPSHOT = "notify.snapshot"
    const val NOTIFY_DISMISS = "notify.dismiss"
    const val NOTIFY_INVOKE = "notify.invoke"
    const val NOTIFY_RESULT = "notify.result"
    const val NOTIFY_FILTER = "notify.filter"
    const val NOTIFY_ICON_REQUEST = "notify.icon_request"
    const val NOTIFY_ICON = "notify.icon"
    const val NOTIFY_AVAILABILITY = "notify.availability"
    const val CONTACTS_SYNC = "contacts.sync"
    const val CONTACTS_BATCH = "contacts.batch"
    const val CONTACTS_AVAILABILITY = "contacts.availability"
    const val CALLS_STATE = "calls.state"
    const val CALLS_COMMAND = "calls.command"
    const val CALLS_RESULT = "calls.result"
    const val CALLS_MISSED = "calls.missed"
    const val CALLS_AVAILABILITY = "calls.availability"

    val ALL: List<String> = listOf(
        HELLO, PING, PONG, ERROR, GOODBYE, PAIR_REQUEST, PAIR_VERIFIED, PAIR_CONFIRM,
        PAIR_COMPLETE, STATUS_UPDATE, FIND_RING, FIND_STOP, FIND_STATE,
        NOTIFY_POSTED, NOTIFY_REMOVED, NOTIFY_SNAPSHOT, NOTIFY_DISMISS, NOTIFY_INVOKE,
        NOTIFY_RESULT, NOTIFY_FILTER, NOTIFY_ICON_REQUEST, NOTIFY_ICON, NOTIFY_AVAILABILITY,
        CONTACTS_SYNC, CONTACTS_BATCH, CONTACTS_AVAILABILITY, CALLS_STATE, CALLS_COMMAND,
        CALLS_RESULT, CALLS_MISSED, CALLS_AVAILABILITY,
    )
}
