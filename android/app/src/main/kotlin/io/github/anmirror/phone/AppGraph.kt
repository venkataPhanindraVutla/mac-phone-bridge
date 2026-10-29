package io.github.anmirror.phone

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager
import android.util.AtomicFile
import android.util.Log
import com.google.protobuf.MessageLite
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.edit
import io.github.anmirror.connection.BulkConnector
import io.github.anmirror.connection.BulkStream
import io.github.anmirror.connection.ConnectionManager
import io.github.anmirror.connection.PhoneConnectionState
import io.github.anmirror.connection.PROTOCOL_VERSION
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PairedMacStore
import io.github.anmirror.connection.PhonePairingClient
import io.github.anmirror.connection.TlsConnector
import io.github.anmirror.connection.TlsIdentity
import io.github.anmirror.feature.clipboard.AndroidClipboard
import io.github.anmirror.feature.clipboard.ClipboardBridge
import io.github.anmirror.feature.contacts.AndroidContactsSource
import io.github.anmirror.feature.contacts.ContactsSync
import io.github.anmirror.feature.notify.ActionInvoker
import io.github.anmirror.feature.notify.NotificationSnapshot
import io.github.anmirror.feature.notify.NotifyBridge
import io.github.anmirror.feature.photos.MediaStoreLibrary
import io.github.anmirror.feature.photos.PhotosService
import io.github.anmirror.feature.screenshots.MediaStoreImageQuery
import io.github.anmirror.feature.screenshots.ScreenshotDetector
import io.github.anmirror.feature.share.ShareReceiver
import io.github.anmirror.phone.platform.AndroidKeystoreIdentity
import io.github.anmirror.phone.platform.EncryptedPairedMacStore
import io.github.anmirror.phone.platform.KeystoreCipher
import io.github.anmirror.phone.platform.MediaStoreDownloads
import io.github.anmirror.phone.platform.SharedFile
import io.github.anmirror.phone.platform.NsdMacDiscovery
import io.github.anmirror.phone.ui.isGranted
import io.github.anmirror.phone.ui.mediaAccess
import io.github.anmirror.phone.service.ConnectionService
import io.github.anmirror.phone.service.SharedNotifications
import io.github.anmirror.phone.service.TransferNotifier
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.ActionOutcome
import io.github.anmirror.protocol.v1.BulkEndpoint
import io.github.anmirror.protocol.v1.BulkHello
import io.github.anmirror.protocol.v1.Envelope
import io.github.anmirror.protocol.v1.TransferKind
import io.github.anmirror.protocol.v1.TransferOffer
import io.github.anmirror.protocol.v1.TransferReject
import io.github.anmirror.transfer.BulkOpener
import io.github.anmirror.transfer.OutgoingFile
import io.github.anmirror.transfer.TransferEngine
import io.github.anmirror.protocol.v1.Channel as ProtoChannel
import io.github.anmirror.protocol.v1.Hello
import io.github.anmirror.protocol.v1.SetupLevel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import com.google.protobuf.InvalidProtocolBufferException
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

/** Log tag for the whole app. */
const val TAG = "AnMirror"

/**
 * Manual dependency wiring: one instance per process, shared by the activity, the service and
 * the boot receiver.
 */
class AppGraph private constructor(context: Context) {
    private val app = context.applicationContext

    /** Lives as long as the process. */
    val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default +
            CoroutineExceptionHandler { _, e -> Log.e(TAG, "uncaught in app scope", e) },
    )

    /** Created on first use (a Keystore key generation is slow), never on the main thread. */
    val identity: TlsIdentity = object : TlsIdentity {
        private val real by lazy { AndroidKeystoreIdentity() }
        override val certificateDer: ByteArray get() = real.certificateDer
        override fun keyManagers() = real.keyManagers()
    }

    val store = ObservablePairedMacStore(
        EncryptedPairedMacStore(AtomicFile(File(app.filesDir, "paired-macs.bin")), KeystoreCipher()),
    )

    private val connector = TlsConnector(identity)

    val manager = ConnectionManager(
        scope = scope,
        store = store,
        discovery = NsdMacDiscovery(app, scope),
        connector = connector,
        hello = ::hello,
        log = { message, e -> Log.e(TAG, "connection: $message", e) },
    )

    val pairing = PairingController(
        scope = scope,
        pair = PhonePairingClient(connector, identity, deviceName(), deviceModel())::pair,
        store = store,
        manager = manager,
        startService = { ConnectionService.start(app) },
    )

    /** Points at the notification listener while it is connected; empty answers otherwise. */
    val notifyInvoker = DelegatingActionInvoker()

    /** Fed by [io.github.anmirror.phone.service.PhoneNotificationListener]; sends only while [notifyOpen]. */
    val notifyBridge = NotifyBridge(
        ownPackage = app.packageName,
        invoker = notifyInvoker,
        log = { message, e -> Log.e(TAG, "notify: $message", e) },
    ) { type, payload -> sendNotify(type, payload) }

    private val notifyPrefs = app.getSharedPreferences("notify", Context.MODE_PRIVATE)
    private val _notifyOn = MutableStateFlow(notifyPrefs.getBoolean(KEY_NOTIFY_ON, false))

    /** The user's "Show notifications on your Mac" switch. Off until they turn it on. */
    val notifyOn: StateFlow<Boolean> = _notifyOn.asStateFlow()

    private val _notifyAccess = MutableStateFlow(readNotifyAccess())

    /** Whether the user has granted notification access (re-read on resume and by the listener). */
    val notifyAccess: StateFlow<Boolean> = _notifyAccess.asStateFlow()

    /**
     * This connection's handshake state (R7). Used only from the ordered event queue. The bridge
     * remembers what it sent per Mac, so it is told which one this is.
     */
    val notifySession = NotifySession {
        (manager.state.value as? PhoneConnectionState.Connected)?.let { notifyBridge.onConnected(it.mac.id) }
    }

    private val _listenerBound = MutableStateFlow(false)

    /** True while the notification listener service is bound, i.e. while the active list is readable. */
    val listenerBound: StateFlow<Boolean> = _listenerBound.asStateFlow()

    fun setListenerBound(bound: Boolean) {
        _listenerBound.value = bound
    }

    fun setNotifyOn(on: Boolean) {
        notifyPrefs.edit().putBoolean(KEY_NOTIFY_ON, on).apply()
        _notifyOn.value = on
    }

    fun refreshNotifyAccess() {
        _notifyAccess.value = readNotifyAccess()
    }

    private fun readNotifyAccess(): Boolean =
        NotificationManagerCompat.getEnabledListenerPackages(app).contains(app.packageName)

    /** The connected Mac shares notify.v1. */
    fun notifyShared(): Boolean {
        val s = manager.state.value
        return s is PhoneConnectionState.Connected && "notify.v1" in s.shared
    }

    /**
     * The phone sends no `notify.*` content unless the Mac shares notify.v1, the switch is on,
     * access is granted and the listener is bound (without it there is nothing to read or act on).
     */
    fun notifyOpen(): Boolean = notifyShared() && _notifyOn.value && _notifyAccess.value && _listenerBound.value

    /** Sends a `notify.*` message when [notifyOpen]; false (and nothing sent) otherwise. */
    suspend fun sendNotify(type: String, payload: MessageLite, replyTo: Long = 0): Boolean =
        notifyOpen() && manager.send(ProtoChannel.CHANNEL_NOTIFY, type, payload, replyTo)

    /** Reads the address book live and sends it to the Mac; serializes its own sends. */
    val contactsSync = ContactsSync(
        source = AndroidContactsSource(app),
        send = { type, payload -> sendContacts(type, payload) },
    )

    private val contactsPrefs = app.getSharedPreferences("contacts", Context.MODE_PRIVATE)
    private val _contactsOn = MutableStateFlow(contactsPrefs.getBoolean(KEY_CONTACTS_ON, false))

    /** The user's "Share contacts with your Mac" switch. Off until they turn it on. */
    val contactsOn: StateFlow<Boolean> = _contactsOn.asStateFlow()

    private val _contactsGranted = MutableStateFlow(readContactsGranted())

    /** Whether READ_CONTACTS is granted (re-read on resume and after the permission prompt). */
    val contactsGranted: StateFlow<Boolean> = _contactsGranted.asStateFlow()

    fun setContactsOn(on: Boolean) {
        contactsPrefs.edit().putBoolean(KEY_CONTACTS_ON, on).apply()
        _contactsOn.value = on
    }

    fun refreshContactsGranted() {
        _contactsGranted.value = readContactsGranted()
    }

    private fun readContactsGranted(): Boolean = app.isGranted(Manifest.permission.READ_CONTACTS)

    /** The connected Mac shares contacts.v1. */
    fun contactsShared(): Boolean {
        val s = manager.state.value
        return s is PhoneConnectionState.Connected && "contacts.v1" in s.shared
    }

    /** The phone sends no contacts content unless the Mac shares contacts.v1, the switch is on and READ_CONTACTS is granted. */
    fun contactsOpen(): Boolean = contactsShared() && _contactsOn.value && readContactsGranted()

    /** Sends a `contacts.*` message when [contactsOpen]; false (and nothing sent) otherwise. */
    suspend fun sendContacts(type: String, payload: MessageLite): Boolean =
        contactsOpen() && manager.send(ProtoChannel.CHANNEL_CONTACTS, type, payload)

    private val callsPrefs = app.getSharedPreferences("calls", Context.MODE_PRIVATE)
    private val _callsOn = MutableStateFlow(callsPrefs.getBoolean(KEY_CALLS_ON, false))

    /** The user's "Calls on your Mac" switch. Off until they turn it on. */
    val callsOn: StateFlow<Boolean> = _callsOn.asStateFlow()

    private val _callsPermissions = MutableStateFlow(readCallsPermissions())

    /** Which of the calls permissions are granted (re-read on resume and after the permission prompts). */
    val callsPermissions: StateFlow<CallsPermissions> = _callsPermissions.asStateFlow()

    fun setCallsOn(on: Boolean) {
        callsPrefs.edit().putBoolean(KEY_CALLS_ON, on).apply()
        _callsOn.value = on
    }

    fun refreshCallsPermissions() {
        _callsPermissions.value = readCallsPermissions()
    }

    private fun readCallsPermissions() = CallsPermissions(
        phoneState = app.isGranted(Manifest.permission.READ_PHONE_STATE),
        callLog = BuildConfig.FEATURE_CALL_LOG && app.isGranted(Manifest.permission.READ_CALL_LOG),
        answer = BuildConfig.FEATURE_ANSWER_CALLS && app.isGranted(Manifest.permission.ANSWER_PHONE_CALLS),
    )

    /** The connected Mac shares calls.v1. */
    fun callsShared(): Boolean {
        val s = manager.state.value
        return s is PhoneConnectionState.Connected && "calls.v1" in s.shared
    }

    /** The phone sends no calls content unless the Mac shares calls.v1, the switch is on and READ_PHONE_STATE is granted. */
    fun callsOpen(): Boolean = callsShared() && _callsOn.value && app.isGranted(Manifest.permission.READ_PHONE_STATE)

    /** Sends a `calls.*` message when [callsOpen]; false (and nothing sent) otherwise. */
    suspend fun sendCalls(type: String, payload: MessageLite): Boolean =
        callsOpen() && manager.send(ProtoChannel.CHANNEL_CALLS, type, payload)

    private val clipboardPrefs = app.getSharedPreferences("clipboard", Context.MODE_PRIVATE)
    private val _clipboardOn = MutableStateFlow(clipboardPrefs.getBoolean(KEY_CLIPBOARD_ON, false))

    /** The user's "Share clipboard with your Mac" switch. Off until they turn it on. No permission is needed. */
    val clipboardOn: StateFlow<Boolean> = _clipboardOn.asStateFlow()

    fun setClipboardOn(on: Boolean) {
        clipboardPrefs.edit { putBoolean(KEY_CLIPBOARD_ON, on) }
        _clipboardOn.value = on
    }

    /** Whether the phone may send its clipboard now, and if not, why. */
    fun clipboardGateNow(): ClipboardGate = clipboardGate(manager.state.value, _clipboardOn.value)

    /** The phone sends and takes no clipboard text unless the Mac shares clipboard.v1 and the switch is on. */
    fun clipboardOpen(): Boolean = clipboardGateNow() == ClipboardGate.OPEN

    /** [clipboardGateNow] as it changes, for the Quick Settings tile. */
    val clipboardGates: Flow<ClipboardGate> =
        combine(manager.state, clipboardOn, ::clipboardGate).distinctUntilChanged()

    /** Sends a `clipboard.*` message when [clipboardOpen]; false (and nothing sent) otherwise. */
    suspend fun sendClipboard(type: String, payload: MessageLite): Boolean =
        clipboardOpen() && manager.send(ProtoChannel.CHANNEL_CLIPBOARD, type, payload)

    /** Writes the Mac's text; sends the phone's on an explicit trigger ([io.github.anmirror.phone.share.ClipboardSendActivity]). */
    val clipboard = ClipboardBridge(AndroidClipboard(app), ::sendClipboard)

    /** The connected Mac's name, for "Sent to %1$s"; null when not connected. */
    fun connectedMacName(): String? = (manager.state.value as? PhoneConnectionState.Connected)?.mac?.name

    /** The connected Mac shares [capability]. */
    private fun shares(capability: String): Boolean {
        val s = manager.state.value
        return s is PhoneConnectionState.Connected && capability in s.shared
    }

    /** The connected Mac shares share.v1. There is no switch and no permission: sharing is always explicit. */
    fun shareShared(): Boolean = shares("share.v1")

    /** Sends a `share.*` message when [shareShared]; false (and nothing sent) otherwise. */
    suspend fun sendShare(type: String, payload: MessageLite): Boolean =
        shareShared() && manager.send(ProtoChannel.CHANNEL_SHARE, type, payload)

    /** Links and text from the Mac (`share.*`); text goes on the clipboard and is remembered (R6). */
    val shareReceiver = ShareReceiver(clipboard, SharedNotifications(app)) {
        connectedMacName() ?: app.getString(R.string.clipboard_mac_unnamed)
    }

    /** The connected Mac shares files.v1: phone-initiated file sends (the share target) need it. */
    fun filesShared(): Boolean = shares("files.v1")

    /** `files.*` flows while the Mac shares any feature it carries (R5). */
    fun transferShared(): Boolean {
        val s = manager.state.value
        return s is PhoneConnectionState.Connected && bulkShared(s.shared)
    }

    /**
     * Sends a `files.*` message when [transferShared]; false (and nothing sent) otherwise. A
     * screenshot offer also needs [screenshotsOpen], and a photo offer [photosOpen] (R5): the
     * transfer fails before the Mac hears of it.
     */
    suspend fun sendTransfer(type: String, payload: MessageLite): Boolean {
        if (!transferShared()) return false
        if (payload is TransferOffer &&
            !phoneOfferAllowed(payload.kind, screenshotsOpen = screenshotsOpen(), photosOpen = photosOpen())
        ) {
            return false
        }
        return manager.send(ProtoChannel.CHANNEL_FILES, type, payload)
    }

    /** The Mac's bulk port, valid only for the session that announced it. */
    private class Endpoint(val session: PhoneConnectionState.Connected, val port: Int)

    private val bulkEndpoint = MutableStateFlow<Endpoint?>(null)
    private val bulkConnector = BulkConnector(connector)

    /** Received files land in Download/Android Mirroring. */
    val downloads = MediaStoreDownloads(app)

    /**
     * Phone side of `files.*`. Its own supervised scope: an orphaned bulk dial that throws must
     * not cancel the engine (or anything else).
     */
    val transfers = TransferEngine(
        scope = CoroutineScope(
            SupervisorJob() + Dispatchers.Default +
                // The class only: a message could carry a path, and so a file name.
                CoroutineExceptionHandler { _, e -> Log.e(TAG, "uncaught in transfers: ${e.javaClass.simpleName}") },
        ),
        send = ::sendTransfer,
        bulk = BulkOpener(::openBulk),
        sinks = downloads,
        freeBytes = { downloads.freeBytes() },
    )

    /** Shared files, screenshots and photos whose descriptors stay open until their transfer ends. */
    private val openShares = ConcurrentHashMap<String, Closeable>()

    /** Queues [files] for sending (the caller checked [filesShared]); each descriptor is closed when its transfer ends. */
    fun sendFiles(files: List<SharedFile>): List<String> = track(transfers.send(files), files)

    /** Remembers the descriptors of the transfers [ids] (in [files]' order), to close when each ends. */
    private fun track(ids: List<String>, files: List<OutgoingFile>): List<String> {
        ids.zip(files).forEach { (id, file) -> (file as? Closeable)?.let { openShares[id] = it } }
        releaseFinished() // one may have ended before it was tracked
        return ids
    }

    private val screenshotsPrefs = app.getSharedPreferences("screenshots", Context.MODE_PRIVATE)
    private val _screenshotsOn = MutableStateFlow(screenshotsPrefs.getBoolean(KEY_SCREENSHOTS_ON, false))

    /** The user's "Send screenshots to your Mac" switch. Off until they turn it on. */
    val screenshotsOn: StateFlow<Boolean> = _screenshotsOn.asStateFlow()

    private val _mediaAccess = MutableStateFlow(app.mediaAccess())

    /** How much of the photos this app may read (re-read on resume and after the permission prompt). */
    val mediaAccess: StateFlow<MediaAccess> = _mediaAccess.asStateFlow()

    fun setScreenshotsOn(on: Boolean) {
        screenshotsPrefs.edit { putBoolean(KEY_SCREENSHOTS_ON, on) }
        _screenshotsOn.value = on
    }

    fun refreshMediaAccess() {
        _mediaAccess.value = app.mediaAccess()
    }

    /** The connected Mac shares screenshots.v1. */
    fun screenshotsShared(): Boolean = shares("screenshots.v1")

    /**
     * The phone sends no screenshot unless the Mac shares screenshots.v1, the switch is on and all
     * photos are readable (with only some, new screenshots can't be found).
     */
    fun screenshotsOpen(): Boolean = screenshotsShared() && _screenshotsOn.value && app.mediaAccess() == MediaAccess.FULL

    private val images = MediaStoreImageQuery(app.contentResolver)

    /** Fed by the service's MediaStore observer while [screenshotsOpen]; reset each time it opens. */
    val screenshotDetector = ScreenshotDetector(images, System::currentTimeMillis)

    /**
     * Sends the screenshots added since the last look, as `TRANSFER_KIND_SCREENSHOT`, when
     * [screenshotsOpen]. Blocks on MediaStore: call off the main thread. Each image's descriptor
     * is closed when its transfer ends.
     */
    fun sendNewScreenshots() {
        if (!screenshotsOpen()) return
        val files = screenshotDetector.onChange().mapNotNull { images.open(it.id) }
        if (files.isEmpty()) return
        if (!screenshotsOpen()) {
            files.forEach { (it as? Closeable)?.close() }
            return
        }
        val ids = track(transfers.send(files, TransferKind.TRANSFER_KIND_SCREENSHOT), files)
        Log.i(TAG, "screenshots: queued ${ids.joinToString(",")}")
    }

    private val photosPrefs = app.getSharedPreferences("photos", Context.MODE_PRIVATE)
    private val _photosOn = MutableStateFlow(photosPrefs.getBoolean(KEY_PHOTOS_ON, false))

    /** The user's "Show recent photos on your Mac" switch. Off until they turn it on. */
    val photosOn: StateFlow<Boolean> = _photosOn.asStateFlow()

    fun setPhotosOn(on: Boolean) {
        photosPrefs.edit { putBoolean(KEY_PHOTOS_ON, on) }
        _photosOn.value = on
    }

    /** The connected Mac shares photos.v1. */
    fun photosShared(): Boolean = shares("photos.v1")

    /**
     * The phone answers no `photos.*` request and sends no photo unless the Mac shares photos.v1,
     * the switch is on and some photos are readable (with only the picked ones, those are listed).
     */
    fun photosOpen(): Boolean = photosShared() && _photosOn.value && app.mediaAccess() != MediaAccess.NONE

    /**
     * Sends a photos answer when [photosOpen]; false (and nothing sent) otherwise. Its
     * `files.failed` (a fetch that found nothing) goes on the files channel, through [sendTransfer].
     */
    suspend fun sendPhotos(type: String, payload: MessageLite): Boolean {
        if (!photosOpen()) return false
        return if (type.startsWith("files.")) sendTransfer(type, payload) else manager.send(ProtoChannel.CHANNEL_PHOTOS, type, payload)
    }

    /**
     * `photos.*` from the Mac (F-13): lists, thumbnails over one bulk stream, and fetches sent as
     * `TRANSFER_KIND_PHOTO`, each descriptor closed when its transfer ends. The caller checks
     * [photosOpen] before handing a request over.
     */
    val photos = PhotosService(
        library = MediaStoreLibrary(app.contentResolver),
        send = ::sendPhotos,
        bulk = BulkOpener(::openBulk),
        transfers = transfers,
        partial = { app.mediaAccess() == MediaAccess.PARTIAL },
        onQueued = { id, file -> track(listOf(id), listOf(file)) },
        log = { Log.i(TAG, it) },
    )

    /**
     * Closes the descriptors of shares whose transfer ended. The tracked IDs are taken before the
     * engine's list is read, so a share queued meanwhile is either not looked at or seen as live.
     */
    private fun releaseFinished() {
        val tracked = openShares.keys.toList()
        for (id in sharesToRelease(tracked, transfers.transfers.value)) openShares.remove(id)?.close()
    }

    /** Transfers the user cancelled on the phone: they add nothing to the results notification (R9). */
    private val cancelledHere = object : LinkedHashSet<String>() {
        override fun add(element: String): Boolean {
            if (size >= KEEP_CANCELLED) remove(first())
            return super.add(element)
        }
    }

    /** The notification's Cancel. */
    fun cancelTransfer(id: String) {
        synchronized(cancelledHere) { cancelledHere.add(id) }
        transfers.cancel(id)
    }

    /**
     * Routes a `files.*` message from the Mac. `files.endpoint` is ours (the engine returns it
     * unhandled); a Mac offer the phone may not take (R5) is rejected here, before the engine
     * lists it; the rest goes to the engine. Nothing is taken unless a bulk feature is shared.
     */
    suspend fun onFilesMessage(env: Envelope) {
        val s = manager.state.value as? PhoneConnectionState.Connected ?: return
        if (!bulkShared(s.shared)) return
        try {
            when (env.type) {
                MessageType.FILES_ENDPOINT -> {
                    val port = BulkEndpoint.parseFrom(env.payload).port
                    if (port in 1..65_535) bulkEndpoint.value = Endpoint(s, port)
                    return
                }
                MessageType.FILES_OFFER -> {
                    val offer = TransferOffer.parseFrom(env.payload)
                    val reason = offerRefusal(offer.hasTarget(), s.shared)
                    if (reason != null) {
                        Log.i(TAG, "transfers: ${offer.transferId} refused $reason")
                        val reject = TransferReject.newBuilder().setTransferId(offer.transferId).setReason(reason).build()
                        manager.send(ProtoChannel.CHANNEL_FILES, MessageType.FILES_REJECT, reject)
                        return
                    }
                }
            }
        } catch (e: InvalidProtocolBufferException) {
            Log.w(TAG, "transfers: bad ${env.type} payload")
            return
        }
        transfers.onMessage(env)
    }

    /**
     * [ended] is over: fail its unfinished transfers and forget its endpoint (an endpoint a newer
     * session already announced stays).
     */
    fun onSessionEnded(ended: PhoneConnectionState.Connected) {
        bulkEndpoint.update { if (it?.session === ended) null else it }
        photos.stop()
        transfers.onDisconnected()
    }

    /**
     * Dials the Mac's bulk port for this session. Never lets a timeout escape as a cancellation
     * (the engine would take it for its own): a slow dial is an IOException, and a stream that
     * arrives after giving up is closed.
     */
    private suspend fun openBulk(hello: BulkHello): BulkStream {
        val ep = withTimeoutOrNull(ENDPOINT_WAIT_MS) {
            bulkEndpoint.filterNotNull().first { it.session === manager.state.value }
        } ?: throw IOException("no bulk endpoint")
        val s = manager.state.value
        if (s !== ep.session) throw IOException("session ended")
        val host = ep.session.mac.lastHost ?: throw IOException("no host")
        val dialed = AtomicReference<BulkStream?>(null)
        try {
            val stream = withTimeoutOrNull(BULK_DIAL_MS) {
                bulkConnector.open(host, ep.port, ep.session.mac.fingerprintHex, hello).also { dialed.set(it) }
            }
            if (stream == null) {
                dialed.getAndSet(null)?.let { runCatching { it.close() } }
                throw IOException("bulk dial timed out")
            }
            return stream
        } catch (e: CancellationException) {
            dialed.getAndSet(null)?.let { runCatching { it.close() } }
            throw e
        }
    }

    /** Points at the notification listener while it is bound; the active call notification comes from it. */
    val callNotifications = DelegatingCallNotifications(app)

    private val notifyEvents = Channel<suspend () -> Unit>(Channel.UNLIMITED)

    /** Queues a listener event; they run one at a time, in the order the listener saw them. */
    fun postNotifyEvent(event: suspend () -> Unit) {
        notifyEvents.trySend(event)
    }

    init {
        scope.launch {
            for (event in notifyEvents) {
                try {
                    event()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.e(TAG, "notify event failed", e)
                }
            }
        }
        scope.launch { store.all() } // load once so the UI knows whether a Mac is paired
        scope.launch { transfers.transfers.collect { releaseFinished() } }
        TransferNotifier(
            app,
            transfers.transfers,
            saved = downloads::saved,
            cancelledHere = { synchronized(cancelledHere) { cancelledHere.toSet() } },
        ).launchIn(scope)
    }

    private fun hello(): Hello = Hello.newBuilder()
        .setProtocolVersion(PROTOCOL_VERSION)
        .setAppVersion(BuildConfig.VERSION_NAME)
        .addAllCapabilities(CAPABILITIES)
        .setSetupLevel(SetupLevel.SETUP_LEVEL_BASIC)
        .setDeviceName(deviceName())
        .setDeviceModel(deviceModel())
        .build()

    private fun deviceName(): String =
        Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: deviceModel()

    private fun deviceModel(): String {
        val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        return if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) Build.MODEL else "$maker ${Build.MODEL}"
    }

    companion object {
        /** Features this phone offers in `system.hello` (SPEC 3). */
        val CAPABILITIES = listOf("status.v1", "find.v1", "notify.v1", "contacts.v1", "calls.v1", "clipboard.v1", "share.v1", "files.v1", "screenshots.v1", "photos.v1")
        private const val KEY_NOTIFY_ON = "show_on_mac"
        private const val KEY_CONTACTS_ON = "share_with_mac"
        private const val KEY_CALLS_ON = "calls_on_mac"
        private const val KEY_CLIPBOARD_ON = "share_with_mac"
        private const val KEY_SCREENSHOTS_ON = "send_to_mac"
        private const val KEY_PHOTOS_ON = "show_on_mac"

        /** The Mac announces its bulk port right after connect (SPEC 13); a share just after connecting waits this long. */
        private const val ENDPOINT_WAIT_MS = 10_000L
        private const val BULK_DIAL_MS = 15_000L
        private const val KEEP_CANCELLED = 100

        // Holds only the application context, which lives as long as the process.
        @SuppressLint("StaticFieldLeak")
        @Volatile private var instance: AppGraph? = null

        fun get(context: Context): AppGraph =
            instance ?: synchronized(this) { instance ?: AppGraph(context).also { instance = it } }
    }
}

/** A [PairedMacStore] that also publishes the list, so the UI can show it. */
class ObservablePairedMacStore(private val inner: PairedMacStore) : PairedMacStore {
    private val _macs = MutableStateFlow<List<PairedMac>?>(null)

    /** Null until first read. */
    val macs: StateFlow<List<PairedMac>?> = _macs.asStateFlow()

    override suspend fun all(): List<PairedMac> = inner.all().also { _macs.value = it }

    override suspend fun save(mac: PairedMac) {
        inner.save(mac)
        _macs.value = inner.all()
    }

    override suspend fun remove(id: String) {
        inner.remove(id)
        _macs.value = inner.all()
    }
}

/** The listener service comes and goes; this lets the process-wide bridge outlive it. */
class DelegatingActionInvoker : ActionInvoker {
    @Volatile var target: ActionInvoker? = null

    override fun invoke(key: String, actionIndex: Int, replyText: String?): ActionOutcome =
        target?.invoke(key, actionIndex, replyText) ?: ActionOutcome.ACTION_OUTCOME_GONE

    override fun dismiss(key: String) { target?.dismiss(key) }
    /** Null (unreadable, not empty) while the listener is not connected. */
    override fun active(): List<NotificationSnapshot>? = target?.active()
    override fun image(key: String): ByteArray? = target?.image(key)
    override fun icon(packageName: String): ByteArray? = target?.icon(packageName)
}

/** The calls permissions that are granted; only [phoneState] is required. */
data class CallsPermissions(val phoneState: Boolean, val callLog: Boolean, val answer: Boolean)

/**
 * The active `category == call` notification of the default dialer / in-call UI, read through the
 * notification listener while it is bound. Call notifications of other apps (WhatsApp, Meet, ...)
 * are ignored: they are neither fired nor used as caller identity. Everything is null when the
 * listener is not bound (feature/calls cannot see the listener itself).
 */
class DelegatingCallNotifications(context: Context) {
    private val app = context.applicationContext

    @Volatile var active: (() -> List<StatusBarNotification>?)? = null

    /** Set by the service while the controller exists; called when a dialer call notification is posted. */
    @Volatile var onDialerCallPosted: (() -> Unit)? = null

    private fun dialerPackages(): Set<String> {
        val telecom = app.getSystemService(TelecomManager::class.java) ?: return emptySet()
        return try {
            setOfNotNull(telecom.defaultDialerPackage, telecom.systemDialerPackage)
        } catch (e: RuntimeException) {
            emptySet()
        }
    }

    fun isDialerCall(sbn: StatusBarNotification): Boolean =
        sbn.notification.category == Notification.CATEGORY_CALL && sbn.packageName in dialerPackages()

    fun notification(): Notification? = active?.invoke()?.firstOrNull { isDialerCall(it) }?.notification

    /** Title of the call notification: the caller's number or name. */
    fun title(): String? = notification()?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
}
