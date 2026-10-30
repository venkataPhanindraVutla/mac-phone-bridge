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
    const val CLIPBOARD_TEXT = "clipboard.text"
    const val CLIPBOARD_AVAILABILITY = "clipboard.availability"
    const val SHARE_LINK = "share.link"
    const val SHARE_TEXT = "share.text"
    const val FILES_ENDPOINT = "files.endpoint"
    const val FILES_OFFER = "files.offer"
    const val FILES_ACCEPT = "files.accept"
    const val FILES_REJECT = "files.reject"
    const val FILES_PROGRESS = "files.progress"
    const val FILES_COMPLETE = "files.complete"
    const val FILES_RECEIVED = "files.received"
    const val FILES_CANCEL = "files.cancel"
    const val FILES_FAILED = "files.failed"
    const val BULK_HELLO = "bulk.hello"
    const val SCREENSHOTS_AVAILABILITY = "screenshots.availability"
    const val PHOTOS_LIST = "photos.list"
    const val PHOTOS_ITEMS = "photos.items"
    const val PHOTOS_THUMBS = "photos.thumbs"
    const val PHOTOS_FETCH = "photos.fetch"
    const val PHOTOS_AVAILABILITY = "photos.availability"
    const val BROWSE_ROOTS_REQUEST = "browse.roots_request"
    const val BROWSE_ROOTS = "browse.roots"
    const val BROWSE_LIST = "browse.list"
    const val BROWSE_LISTING = "browse.listing"
    const val BROWSE_STAT = "browse.stat"
    const val BROWSE_MKDIR = "browse.mkdir"
    const val BROWSE_DELETE = "browse.delete"
    const val BROWSE_READ = "browse.read"
    const val BROWSE_RENAME = "browse.rename"
    const val BROWSE_RESULT = "browse.result"
    const val BROWSE_AVAILABILITY = "browse.availability"
    const val MEDIA_STATE = "media.state"
    const val MEDIA_ARTWORK = "media.artwork"
    const val MEDIA_COMMAND = "media.command"
    const val MEDIA_AVAILABILITY = "media.availability"
    const val DND_STATE = "dnd.state"
    const val DND_AVAILABILITY = "dnd.availability"
    const val PROXIMITY_AVAILABILITY = "proximity.availability"
    const val INPUT_MOVE = "input.move"
    const val INPUT_BUTTON = "input.button"
    const val INPUT_CLICK = "input.click"
    const val INPUT_SCROLL = "input.scroll"
    const val INPUT_KEY = "input.key"
    const val INPUT_LASER = "input.laser"
    const val INPUT_AVAILABILITY = "input.availability"

    val ALL: List<String> = listOf(
        HELLO, PING, PONG, ERROR, GOODBYE, PAIR_REQUEST, PAIR_VERIFIED, PAIR_CONFIRM,
        PAIR_COMPLETE, STATUS_UPDATE, FIND_RING, FIND_STOP, FIND_STATE,
        NOTIFY_POSTED, NOTIFY_REMOVED, NOTIFY_SNAPSHOT, NOTIFY_DISMISS, NOTIFY_INVOKE,
        NOTIFY_RESULT, NOTIFY_FILTER, NOTIFY_ICON_REQUEST, NOTIFY_ICON, NOTIFY_AVAILABILITY,
        CONTACTS_SYNC, CONTACTS_BATCH, CONTACTS_AVAILABILITY, CALLS_STATE, CALLS_COMMAND,
        CALLS_RESULT, CALLS_MISSED, CALLS_AVAILABILITY,
        CLIPBOARD_TEXT, CLIPBOARD_AVAILABILITY, SHARE_LINK, SHARE_TEXT, FILES_ENDPOINT, FILES_OFFER,
        FILES_ACCEPT, FILES_REJECT, FILES_PROGRESS, FILES_COMPLETE, FILES_RECEIVED, FILES_CANCEL,
        FILES_FAILED, BULK_HELLO, SCREENSHOTS_AVAILABILITY, PHOTOS_LIST, PHOTOS_ITEMS,
        PHOTOS_THUMBS, PHOTOS_FETCH, PHOTOS_AVAILABILITY, BROWSE_ROOTS_REQUEST, BROWSE_ROOTS,
        BROWSE_LIST, BROWSE_LISTING, BROWSE_STAT, BROWSE_MKDIR, BROWSE_DELETE, BROWSE_READ,
        BROWSE_RENAME, BROWSE_RESULT, BROWSE_AVAILABILITY,
        MEDIA_STATE, MEDIA_ARTWORK, MEDIA_COMMAND, MEDIA_AVAILABILITY, DND_STATE, DND_AVAILABILITY,
        PROXIMITY_AVAILABILITY, INPUT_MOVE, INPUT_BUTTON, INPUT_CLICK, INPUT_SCROLL, INPUT_KEY,
        INPUT_LASER, INPUT_AVAILABILITY,
    )
}
