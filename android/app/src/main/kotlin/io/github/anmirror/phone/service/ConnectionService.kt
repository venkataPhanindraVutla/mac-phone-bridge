package io.github.anmirror.phone.service

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.ContactsContract
import android.provider.MediaStore
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PhoneConnectionState
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.BuildConfig
import io.github.anmirror.phone.MainActivity
import io.github.anmirror.phone.MediaAccess
import io.github.anmirror.phone.PairingState
import io.github.anmirror.phone.R
import io.github.anmirror.phone.TAG
import io.github.anmirror.phone.diag.KeepAliveEvent
import io.github.anmirror.phone.answerInvoke
import io.github.anmirror.phone.clipboardTracksMac
import io.github.anmirror.phone.featureAvailability
import io.github.anmirror.phone.copyNamesMac
import io.github.anmirror.phone.DndAvailabilityOnSession
import io.github.anmirror.phone.macOrNull
import io.github.anmirror.phone.mediaFeatureAvailability
import io.github.anmirror.phone.messageRes
import io.github.anmirror.phone.proximityAvailability
import io.github.anmirror.phone.platform.NetworkWatcher
import io.github.anmirror.phone.share.ClipboardSendActivity
import io.github.anmirror.connection.PhoneConnectionState.Connected
import io.github.anmirror.feature.calls.AndroidCallStateSource
import io.github.anmirror.feature.calls.AndroidMicMute
import io.github.anmirror.feature.calls.CallsRuntime
import io.github.anmirror.feature.calls.CallController
import io.github.anmirror.feature.calls.CallLogMissedCallLookup
import io.github.anmirror.feature.calls.CallStyleCallActions
import io.github.anmirror.feature.calls.TelecomCallActions
import io.github.anmirror.feature.find.AndroidAlarmAudio
import io.github.anmirror.feature.screenshots.ChangeDebounce
import io.github.anmirror.feature.find.AndroidDndOverride
import io.github.anmirror.feature.find.AndroidRingNotifier
import io.github.anmirror.feature.find.PrefsRingSavedStore
import io.github.anmirror.feature.find.RingController
import io.github.anmirror.feature.proximity.AdvertiserState
import io.github.anmirror.feature.status.AndroidStatusSource
import io.github.anmirror.feature.status.StatusPublisher
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.BrowseListRequest
import io.github.anmirror.protocol.v1.BrowsePath
import io.github.anmirror.protocol.v1.BrowseRename
import io.github.anmirror.protocol.v1.BrowseRootsRequest
import io.github.anmirror.protocol.v1.CallCommand
import io.github.anmirror.protocol.v1.CallCommandOutcome
import io.github.anmirror.protocol.v1.CallCommandResult
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.ClipboardText
import io.github.anmirror.protocol.v1.ContactsSyncRequest
import io.github.anmirror.protocol.v1.DismissNotification
import io.github.anmirror.protocol.v1.DndAvailability
import io.github.anmirror.protocol.v1.DndState
import io.github.anmirror.protocol.v1.FeatureAvailability
import io.github.anmirror.protocol.v1.IconRequest
import io.github.anmirror.protocol.v1.InvokeAction
import io.github.anmirror.protocol.v1.MediaCommand
import io.github.anmirror.protocol.v1.NotificationFilter
import io.github.anmirror.protocol.v1.PhotoFetch
import io.github.anmirror.protocol.v1.PhotosListRequest
import io.github.anmirror.protocol.v1.PhotosThumbsRequest
import io.github.anmirror.protocol.v1.SharedLink
import io.github.anmirror.protocol.v1.SharedText
import io.github.anmirror.protocol.v1.TransferKind
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicReference

/**
 * Keeps the phone connected to its Mac: a `connectedDevice` foreground service that runs the
 * [io.github.anmirror.connection.ConnectionManager] and kicks it on network changes. Sticky, and
 * started at boot when a Mac is paired. Stops itself once no Mac is paired.
 */
class ConnectionService : LifecycleService() {
    private lateinit var graph: AppGraph

    /** The wait-then-kick after a `NotPaired` the store did not confirm; one per episode. */
    private var notPairedJob: Job? = null
    private lateinit var network: NetworkWatcher
    private var lastText: String? = null
    private lateinit var ring: RingController
    private var lastNotifyEnabled: Boolean? = null
    /** Whether the persistent notification carries "Send clipboard": connected, shared and on. */
    private var clipboardAction = false

    override fun onCreate() {
        super.onCreate()
        running = true
        graph = AppGraph.get(this)
        graph.keepAliveLog.record(KeepAliveEvent.SERVICE_CREATE)
        createChannel()
        goForeground(getString(R.string.state_looking_unnamed))
        network = NetworkWatcher(this) { graph.manager.kick() }
        network.start()
        graph.manager.start()
        // Phone status goes out only while the Mac shares status.v1.
        StatusPublisher(
            source = AndroidStatusSource(this),
            connected = graph.manager.state.map { it is Connected && "status.v1" in it.shared },
            send = { graph.manager.send(Channel.CHANNEL_STATUS, MessageType.STATUS_UPDATE, it) },
        ).launchIn(lifecycleScope)
        setUpFindMyPhone()
        setUpNotifications()
        setUpContacts()
        setUpCalls()
        setUpClipboard()
        setUpShare()
        setUpTransfers()
        setUpScreenshots()
        setUpPhotos()
        setUpBrowse()
        setUpMedia()
        setUpDnd()
        setUpProximity()
        setUpInput()
        lifecycleScope.launch {
            combine(graph.manager.state, graph.store.macs, graph.pairing.state) { state, macs, pairing ->
                Triple(state, macs, pairing.isUnderWay())
            }
                .distinctUntilChanged()
                .collect { (state, macs, pairing) -> onState(state, macs, pairing) }
        }
        Log.i(TAG, "service: created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent?.action == ACTION_STOP_RING && ::ring.isInitialized) ring.stop() // the Stop action / tap on the ring notification
        // Every start must be followed by startForeground, also a sticky restart.
        goForeground(lastText ?: getString(R.string.state_looking_unnamed))
        Log.i(TAG, "service: start (restart=${intent == null})")
        graph.keepAliveLog.record(KeepAliveEvent.SERVICE_START, "restart=${intent == null}")
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        graph.keepAliveLog.record(KeepAliveEvent.SERVICE_DESTROY)
        _ringing.value = false
        if (::ring.isInitialized) ring.stop() // the service going away must not leave an alarm behind
        stopContactsObserver()
        stopScreenshotObserver()
        if (mediaBridgeOpen) {
            mediaBridgeOpen = false
            graph.mediaBridge.onDisconnected()
        }
        stopDndReceiver()
        synchronized(dndLock) {
            if (dndSession != null) graph.dndSync.onDisconnected()
            dndSession = null
        }
        stopProximityReceiver()
        graph.proximityBeacon.stop() // its sets and its alarm
        graph.callNotifications.onDialerCallPosted = null
        calls.stop()
        network.stop()
        graph.manager.stop()
        // The collector never sees Stopped once cancelled: end the session here (getAndSet: exactly one of us does).
        sessionWatch?.cancel()
        session.getAndSet(null)?.let(graph::onSessionEnded)
        Log.i(TAG, "service: destroyed")
        super.onDestroy()
    }

    /**
     * The ring lives here, not in the connection: a dropped connection does not stop it. It stops
     * on find.stop, on the notification's Stop, or when this service is destroyed.
     */
    private fun setUpFindMyPhone() {
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, ConnectionService::class.java).setAction(ACTION_STOP_RING),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        ring = RingController(
            audio = AndroidAlarmAudio(this),
            dnd = AndroidDndOverride(this),
            notifier = AndroidRingNotifier(this, stop),
            store = PrefsRingSavedStore(this),
            onState = { state ->
                lifecycleScope.launch { graph.manager.send(Channel.CHANNEL_FIND, MessageType.FIND_STATE, state) }
            },
        )
        // A previous process may have died mid-ring, leaving max volume / ALARMS behind.
        ring.restoreLeftover()
        lifecycleScope.launch { ring.ringing.collect { _ringing.value = it } }
        graph.manager.on(MessageType.FIND_RING) { ring.start() }
        graph.manager.on(MessageType.FIND_STOP) { ring.stop() }
        // After a reconnect the Mac does not know the phone is still ringing: tell it.
        lifecycleScope.launch {
            graph.manager.state
                .map { it is Connected && "find.v1" in it.shared }
                .distinctUntilChanged()
                .collect { shared -> if (shared && ring.ringing.value) graph.manager.send(Channel.CHANNEL_FIND, MessageType.FIND_STATE, ring.currentState()) }
        }
    }

    /**
     * Notifications: every handler only queues onto the graph's ordered event channel, so the
     * bridge sees the listener's events and the Mac's messages in one order. Nothing is sent
     * unless [AppGraph.notifyOpen]; `notify.availability` is the one message that is, since it is
     * how the Mac learns the feature is off.
     */
    private fun setUpNotifications() {
        val bridge = graph.notifyBridge
        graph.manager.on(MessageType.NOTIFY_FILTER) { env ->
            val filter = NotificationFilter.parseFrom(env.payload)
            graph.postNotifyEvent {
                bridge.onFilter(filter)
                // The Mac sends a filter right after connecting (SPEC 10): the first one starts the session.
                graph.notifySession.filterApplied(graph.listenerBound.value)
            }
        }
        graph.manager.on(MessageType.NOTIFY_DISMISS) { env ->
            val dismiss = DismissNotification.parseFrom(env.payload)
            graph.postNotifyEvent { if (graph.notifyOpen()) bridge.onDismiss(dismiss) }
        }
        graph.manager.on(MessageType.NOTIFY_ICON_REQUEST) { env ->
            val request = IconRequest.parseFrom(env.payload)
            graph.postNotifyEvent { if (graph.notifyOpen()) bridge.onIconRequest(request) }
        }
        graph.manager.on(MessageType.NOTIFY_INVOKE) { env ->
            val invoke = InvokeAction.parseFrom(env.payload)
            graph.postNotifyEvent {
                // Exactly one result per invoke, answering this envelope; FAILED while the feature is closed.
                val result = answerInvoke(invoke.key, graph.notifyShared(), graph.notifyOpen()) { bridge.onInvoke(env.id, invoke) }
                if (result != null) graph.manager.send(Channel.CHANNEL_NOTIFY, MessageType.NOTIFY_RESULT, result, env.id)
            }
        }
        // The listener binding mid-session (boot, restart, access re-granted): catch the Mac up.
        lifecycleScope.launch {
            graph.listenerBound.collect { bound ->
                if (bound) graph.postNotifyEvent { graph.notifySession.listenerBound() }
            }
        }
        lifecycleScope.launch {
            combine(
                graph.manager.state.map { it is Connected && "notify.v1" in it.shared }.distinctUntilChanged(),
                graph.notifyOn,
                graph.notifyAccess,
            ) { connected, on, access -> Triple(connected, on, access) }
                .distinctUntilChanged()
                .collect { (connected, on, access) ->
                    if (!connected) {
                        lastNotifyEnabled = null
                        graph.postNotifyEvent {
                            graph.notifySession.reset()
                            bridge.onDisconnected()
                        }
                        return@collect
                    }
                    val availability = featureAvailability(granted = access, userOn = on)
                    if (lastNotifyEnabled == null) graph.postNotifyEvent { graph.notifySession.reset() }
                    graph.manager.send(Channel.CHANNEL_NOTIFY, MessageType.NOTIFY_AVAILABILITY, availability)
                    // Switched on (or access granted) mid-session: catch the Mac up.
                    if (availability.enabled && lastNotifyEnabled == false) {
                        graph.postNotifyEvent { graph.notifySession.enabled(graph.listenerBound.value) }
                    }
                    lastNotifyEnabled = availability.enabled
                }
        }
    }

    /**
     * Contacts: sent only while [AppGraph.contactsOpen]; `contacts.availability` is the one message
     * that is sent regardless, while the Mac shares contacts.v1. The Mac asks (`contacts.sync`)
     * on connect; a ContentObserver, debounced by 5 s, pushes changes while open.
     */
    private fun setUpContacts() {
        graph.manager.on(MessageType.CONTACTS_SYNC) { env ->
            val request = ContactsSyncRequest.parseFrom(env.payload)
            graph.scope.launch {
                if (!graph.contactsOpen()) return@launch
                try {
                    graph.contactsSync.onSyncRequest(request)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) { // e.g. permission revoked between the check and the read
                    Log.e(TAG, "contacts: sync failed", e)
                }
            }
        }
        lifecycleScope.launch {
            combine(
                graph.manager.state.map { it is Connected && "contacts.v1" in it.shared }.distinctUntilChanged(),
                graph.contactsOn,
                graph.contactsGranted,
            ) { shared, on, granted -> Triple(shared, on, granted) }
                .distinctUntilChanged()
                .collect { (shared, on, granted) ->
                    if (shared) {
                        graph.manager.send(Channel.CHANNEL_CONTACTS, MessageType.CONTACTS_AVAILABILITY, featureAvailability(granted, on))
                    }
                    if (shared && on && granted) startContactsObserver() else stopContactsObserver()
                }
        }
    }

    private val calls = CallsRuntime { newCallController() }

    /**
     * Calls: the controller (and its telephony source) lives while the switch is on and
     * READ_PHONE_STATE is granted, and only then (a reconnect never rebuilds it, so a call keeps its
     * call_id); what it sends goes through [AppGraph.sendCalls], which sends only while the Mac
     * shares calls.v1. `calls.availability` is sent regardless, while the Mac shares calls.v1, and
     * every `calls.command` gets exactly one `calls.result`: NOT_ALLOWED while the feature is
     * closed, FAILED if handling it threw.
     */
    private fun setUpCalls() {
        graph.manager.on(MessageType.CALLS_COMMAND) { env ->
            val command = CallCommand.parseFrom(env.payload)
            graph.scope.launch {
                if (!graph.callsShared()) return@launch
                val controller = calls.controller?.takeIf { graph.callsOpen() }
                val outcome = try {
                    controller?.onCommand(command)?.outcome ?: CallCommandOutcome.CALL_COMMAND_OUTCOME_NOT_ALLOWED
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.e(TAG, "calls: command failed", e)
                    CallCommandOutcome.CALL_COMMAND_OUTCOME_FAILED
                }
                val result = CallCommandResult.newBuilder().setCallId(command.callId).setOutcome(outcome).build()
                graph.manager.send(Channel.CHANNEL_CALLS, MessageType.CALLS_RESULT, result, env.id)
            }
        }
        graph.callNotifications.onDialerCallPosted = { calls.controller?.refreshIdentity() }
        watchCallLogGrant()
        lifecycleScope.launch {
            var wasShared = false
            combine(
                graph.manager.state.map { it is Connected && "calls.v1" in it.shared }.distinctUntilChanged(),
                graph.callsOn,
                graph.callsPermissions.map { it.phoneState }.distinctUntilChanged(),
            ) { shared, on, phoneState -> Triple(shared, on, phoneState) }
                .distinctUntilChanged()
                .collect { (shared, on, phoneState) ->
                    if (shared) {
                        graph.manager.send(Channel.CHANNEL_CALLS, MessageType.CALLS_AVAILABILITY, featureAvailability(phoneState, on))
                    }
                    val created = calls.update(on, phoneState)
                    // The one place the Mac is caught up: it just (re)connected, or the controller just came up while connected.
                    if (shared && (!wasShared || created)) calls.controller?.onConnected()
                    wasShared = shared
                }
        }
    }

    /**
     * READ_CALL_LOG decides whether the source can deliver the incoming number (API 31+, see
     * AndroidCallStateSource): when it flips, only the source restarts; the controller stays.
     */
    private fun watchCallLogGrant() {
        if (!BuildConfig.FEATURE_CALL_LOG || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        lifecycleScope.launch {
            graph.callsPermissions.map { it.callLog }.distinctUntilChanged().drop(1).collect { calls.restartSource() }
        }
    }

    // Both implementations check their permission on every use, so a grant needs no rebuild.
    private fun newCallController() = CallController(
        source = AndroidCallStateSource(this, wantNumber = BuildConfig.FEATURE_CALL_LOG),
        primary = if (BuildConfig.FEATURE_ANSWER_CALLS) TelecomCallActions(this) else null,
        fallback = CallStyleCallActions { graph.callNotifications.notification() },
        mic = AndroidMicMute(this),
        missed = if (BuildConfig.FEATURE_CALL_LOG) CallLogMissedCallLookup(this) else null,
        notificationNumber = { graph.callNotifications.title() },
        clock = System::currentTimeMillis,
        newId = { java.util.UUID.randomUUID().toString() },
        send = { type, payload -> graph.sendCalls(type, payload) },
    )

    /**
     * Clipboard: the Mac's `clipboard.text` is written only while [AppGraph.clipboardOpen]; the
     * phone sends only on an explicit trigger (tile, notification action), each of which opens
     * [ClipboardSendActivity]. `clipboard.availability` is sent regardless, while the
     * Mac shares clipboard.v1. No permission is involved.
     */
    private fun setUpClipboard() {
        graph.manager.on(MessageType.CLIPBOARD_TEXT) { env ->
            val text = ClipboardText.parseFrom(env.payload)
            if (graph.clipboardOpen()) graph.clipboard.onMacText(text)
        }
        lifecycleScope.launch {
            combine(
                graph.manager.state.map { it is Connected && "clipboard.v1" in it.shared }.distinctUntilChanged(),
                graph.clipboardOn,
            ) { shared, on -> shared to on }
                .distinctUntilChanged()
                .collect { (shared, on) ->
                    if (shared) {
                        graph.manager.send(Channel.CHANNEL_CLIPBOARD, MessageType.CLIPBOARD_AVAILABILITY, featureAvailability(granted = true, userOn = on))
                    }
                    // Mac text is dropped meanwhile, so what the bridge knows of the Mac's clipboard goes stale.
                    if (!clipboardTracksMac(shared, on)) graph.clipboard.onDisconnected()
                    val ready = shared && on
                    if (ready != clipboardAction) {
                        clipboardAction = ready
                        lastText?.let(::update)
                    }
                }
        }
    }

    /**
     * Share: links and text from the Mac, taken while it shares share.v1 (no switch: each share
     * is an explicit act on the Mac). Text lands on the clipboard and is remembered there (R6).
     */
    private fun setUpShare() {
        graph.manager.on(MessageType.SHARE_LINK) { env ->
            val link = SharedLink.parseFrom(env.payload)
            if (graph.shareShared()) graph.shareReceiver.onLink(link)
        }
        graph.manager.on(MessageType.SHARE_TEXT) { env ->
            val text = SharedText.parseFrom(env.payload)
            if (graph.shareShared()) graph.shareReceiver.onText(text)
        }
    }

    /** The Connected state of the session in progress; a different state means it ended. */
    private val session = AtomicReference<Connected?>(null)
    private var sessionWatch: Job? = null

    /**
     * Transfers: every `files.*` message goes through [AppGraph.onFilesMessage] (endpoint, R5
     * gating, then the engine). When a session ends, its transfers fail and its endpoint goes.
     */
    private fun setUpTransfers() {
        for (type in FILES_TYPES) graph.manager.on(type) { env -> graph.onFilesMessage(env) }
        // Partial downloads a killed process (or a delete that threw) left behind.
        graph.scope.launch(Dispatchers.IO) { graph.downloads.sweepLeftovers() }
        // Off the main thread, so a busy UI cannot delay failing the old session's transfers.
        sessionWatch = graph.scope.launch {
            graph.manager.state.collect { state ->
                val ended = session.getAndSet(state as? Connected)
                if (ended != null && state !== ended) graph.onSessionEnded(ended)
            }
        }
    }

    /**
     * Screenshots (F-12): while the feature is open (the Mac shares screenshots.v1, the switch is
     * on, all photos are readable) a MediaStore observer, debounced by 500 ms (but looking at least
     * every 1.5 s while changes keep coming), sends each new
     * screenshot as `TRANSFER_KIND_SCREENSHOT`. `screenshots.availability` is sent regardless,
     * while the Mac shares screenshots.v1; with only some photos allowed it says PARTIAL_ACCESS.
     */
    private fun setUpScreenshots() {
        lifecycleScope.launch {
            combine(
                graph.manager.state.map { it is Connected && "screenshots.v1" in it.shared }.distinctUntilChanged(),
                graph.screenshotsOn,
                graph.mediaAccess,
            ) { shared, on, access -> Triple(shared, on, access) }
                .distinctUntilChanged()
                .collect { (shared, on, access) ->
                    if (shared) {
                        val availability = mediaFeatureAvailability(access, on, partialWorks = false)
                        graph.manager.send(Channel.CHANNEL_SCREENSHOTS, MessageType.SCREENSHOTS_AVAILABILITY, availability)
                    }
                    if (shared && on && access == MediaAccess.FULL) {
                        startScreenshotObserver()
                    } else {
                        stopScreenshotObserver()
                        // Screenshots found while it was open but not yet sent go no further.
                        graph.stopSends(TransferKind.TRANSFER_KIND_SCREENSHOT)
                    }
                }
        }
    }

    /**
     * Photos (F-13): `photos.list`, `photos.thumbs` and `photos.fetch` are answered only while the
     * feature is open (the Mac shares photos.v1, the switch is on, some photos are readable); each
     * runs on its own, so a thumbnail stream never holds up the next message. With only the picked
     * photos readable, those are listed. `photos.availability` is sent regardless, while the Mac
     * shares photos.v1; closing the feature ends a thumbnail stream in progress.
     */
    private fun setUpPhotos() {
        graph.manager.on(MessageType.PHOTOS_LIST) { env ->
            val request = PhotosListRequest.parseFrom(env.payload)
            photosRequest("list") { graph.photos.onList(request) }
        }
        graph.manager.on(MessageType.PHOTOS_THUMBS) { env ->
            val request = PhotosThumbsRequest.parseFrom(env.payload)
            photosRequest("thumbs") { graph.photos.onThumbs(request) }
        }
        graph.manager.on(MessageType.PHOTOS_FETCH) { env ->
            val fetch = PhotoFetch.parseFrom(env.payload)
            photosRequest("fetch") { graph.photos.onFetch(fetch) }
        }
        lifecycleScope.launch {
            combine(
                graph.manager.state.map { it is Connected && "photos.v1" in it.shared }.distinctUntilChanged(),
                graph.photosOn,
                graph.photosAccess,
            ) { shared, on, access -> Triple(shared, on, access) }
                .distinctUntilChanged()
                .collect { (shared, on, access) ->
                    if (shared) {
                        val availability = mediaFeatureAvailability(access, on, partialWorks = true)
                        graph.manager.send(Channel.CHANNEL_PHOTOS, MessageType.PHOTOS_AVAILABILITY, availability)
                    }
                    if (!(shared && on && access != MediaAccess.NONE)) {
                        graph.photos.stop()
                        // Fetches queued or under way stop too (the Mac is told).
                        graph.stopSends(TransferKind.TRANSFER_KIND_PHOTO)
                    }
                }
        }
    }

    /** Runs one photos request off the main thread, only while [AppGraph.photosOpen]; logs the failure class only. */
    private fun photosRequest(what: String, handle: suspend () -> Unit) {
        graph.scope.launch(Dispatchers.IO) {
            if (!graph.photosOpen()) return@launch
            try {
                handle()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The class only: a message could carry a path.
                Log.e(TAG, "photos: $what failed (${e.javaClass.simpleName})")
            }
        }
    }

    /**
     * Browse (F-04): `browse.*` requests are answered only while browsing is open (the Mac shares
     * browse.v1, the switch is on, there is a root: All files access or a picked folder); each runs
     * on its own, off the main thread. `browse.availability` is sent regardless, while the Mac
     * shares browse.v1, and `browse.roots` is pushed whenever browsing opens (on connect, say) or
     * the roots change while it is open. When a root goes, its transfers stop; closing browsing stops
     * them all.
     */
    private fun setUpBrowse() {
        graph.manager.on(MessageType.BROWSE_ROOTS_REQUEST) { env ->
            BrowseRootsRequest.parseFrom(env.payload)
            browseRequest("roots") { graph.browse.onRootsRequest() }
        }
        graph.manager.on(MessageType.BROWSE_LIST) { env ->
            val request = BrowseListRequest.parseFrom(env.payload)
            browseRequest("list") { graph.browse.onList(request) }
        }
        graph.manager.on(MessageType.BROWSE_STAT) { env ->
            val path = BrowsePath.parseFrom(env.payload)
            browseRequest("stat") { graph.browse.onStat(path) }
        }
        graph.manager.on(MessageType.BROWSE_MKDIR) { env ->
            val path = BrowsePath.parseFrom(env.payload)
            browseRequest("mkdir") { graph.browse.onMkdir(path) }
        }
        graph.manager.on(MessageType.BROWSE_DELETE) { env ->
            val path = BrowsePath.parseFrom(env.payload)
            browseRequest("delete") { graph.browse.onDelete(path) }
        }
        graph.manager.on(MessageType.BROWSE_RENAME) { env ->
            val rename = BrowseRename.parseFrom(env.payload)
            browseRequest("rename") { graph.browse.onRename(rename) }
        }
        graph.manager.on(MessageType.BROWSE_READ) { env ->
            val path = BrowsePath.parseFrom(env.payload)
            browseRequest("read") { graph.browse.onRead(path) }
        }
        // Picked folders whose grant went away while the app was not running.
        graph.launchQuietly("browse: access refresh") { graph.refreshBrowseAccess() }
        lifecycleScope.launch {
            var wasOpen = false
            combine(
                graph.manager.state.map { it is Connected && "browse.v1" in it.shared }.distinctUntilChanged(),
                graph.browseOn,
                graph.browseRoots,
            ) { shared, on, roots -> Triple(shared, on, roots) }
                .distinctUntilChanged()
                .collect { (shared, on, roots) ->
                    if (shared) {
                        val availability = featureAvailability(granted = roots.isNotEmpty(), userOn = on)
                        graph.manager.send(Channel.CHANNEL_BROWSE, MessageType.BROWSE_AVAILABILITY, availability)
                    }
                    val open = shared && on && roots.isNotEmpty()
                    if (open) browseRequest("push roots") { graph.browse.pushRoots() }
                    // A root removed, revoked or no longer reachable: its transfers stop.
                    if (open) graph.launchQuietly("browse: roots changed") { graph.browse.onRootsChanged() }
                    if (wasOpen && !open) graph.browse.cancelAll()
                    wasOpen = open
                }
        }
    }

    /** Whether [AppGraph.mediaBridge] is started; touched only by the media collector and onDestroy (main thread). */
    private var mediaBridgeOpen = false

    /**
     * Media (F-07): while the feature is open (the Mac shares media.v1, the switch is on and
     * notification access is granted) the bridge watches the phone's media sessions and sends
     * the picked one's state; `media.command` goes to it then and is dropped otherwise.
     * `media.availability` is sent regardless, while the Mac shares media.v1. Each new session,
     * and each change of access, starts the bridge afresh (the sessions are read again, the
     * artwork sent again).
     */
    private fun setUpMedia() {
        graph.manager.on(MessageType.MEDIA_COMMAND) { env ->
            val command = MediaCommand.parseFrom(env.payload)
            if (graph.mediaOpen()) graph.mediaBridge.onCommand(command)
        }
        lifecycleScope.launch {
            var lastSession: Connected? = null
            combine(
                // By identity: a new session of the same Mac with the same capabilities is still new.
                graph.manager.state
                    .map { s -> (s as? Connected)?.takeIf { "media.v1" in it.shared } }
                    .distinctUntilChanged { a, b -> a === b },
                graph.mediaControlOn,
                graph.notifyAccess,
            ) { session, on, access -> Triple(session, on, access) }
                .distinctUntilChanged { a, b -> a.first === b.first && a.second == b.second && a.third == b.third }
                .collect { (session, on, access) ->
                    val open = session != null && on && access
                    if (mediaBridgeOpen && (!open || session !== lastSession)) {
                        mediaBridgeOpen = false
                        graph.mediaBridge.onDisconnected()
                    }
                    lastSession = session
                    if (session != null) {
                        graph.manager.send(Channel.CHANNEL_MEDIA, MessageType.MEDIA_AVAILABILITY, featureAvailability(granted = access, userOn = on))
                    }
                    if (open && !mediaBridgeOpen) {
                        mediaBridgeOpen = true
                        // Off the main thread (session reads, artwork encoding), and finished before the next change.
                        try {
                            withContext(Dispatchers.Default) { graph.mediaBridge.onConnected() }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Log.e(TAG, "media: start failed (${e.javaClass.simpleName})")
                        }
                    }
                }
        }
    }

    private val dndLock = Any()

    /** The session [AppGraph.dndSync]'s Mac state belongs to; guarded by [dndLock]. */
    private var dndSession: Connected? = null

    /**
     * The current session if it shares dnd.v1. A new session clears what the last one's Mac said
     * first, so a handler running before the collector has seen the new session cannot be undone by it.
     */
    private fun dndSessionNow(): Connected? {
        val s = (graph.manager.state.value as? Connected)?.takeIf { "dnd.v1" in it.shared }
        synchronized(dndLock) {
            if (s !== dndSession) {
                if (dndSession != null) graph.dndSync.onDisconnected()
                dndSession = s
            }
        }
        return s
    }

    /** Registered while [AppGraph.dndOpen]; touched only on the main thread. */
    private var dndReceiver: BroadcastReceiver? = null

    private fun startDndReceiver() {
        if (dndReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED ->
                        graph.launchQuietly("dnd: local change") { graph.dndSync.onLocalChange() }
                    NotificationManager.ACTION_NOTIFICATION_POLICY_ACCESS_GRANTED_CHANGED -> graph.refreshDndAccess()
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
            addAction(NotificationManager.ACTION_NOTIFICATION_POLICY_ACCESS_GRANTED_CHANGED)
        }
        // Both are system broadcasts to registered receivers only.
        ContextCompat.registerReceiver(this, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        dndReceiver = receiver
    }

    private fun stopDndReceiver() {
        dndReceiver?.let(::unregisterReceiver)
        dndReceiver = null
    }

    /**
     * Do Not Disturb (F-11): while the feature is open (the Mac shares dnd.v1 and the switch is on)
     * the filter broadcasts go to [AppGraph.dndSync], which sends the phone's transitions and
     * applies the Mac's (with Do Not Disturb access); it starts with the snapshot. The Mac's
     * `dnd.state` is dropped while the feature is closed; its `dnd.availability` is kept while it
     * shares dnd.v1. The phone's `dnd.availability` is sent regardless, on connect (with the access
     * read again) and on change.
     *
     * While Find my phone rings, the Mac's state is shown but deferred: applying it could silence
     * the ring, and the ring's restore would undo it. It is applied once the ring has stopped and
     * put the filter back.
     */
    private fun setUpDnd() {
        graph.manager.on(MessageType.DND_STATE) { env ->
            val state = DndState.parseFrom(env.payload)
            if (dndSessionNow() != null && graph.dndSyncOn.value) {
                if (ring.ringing.value) {
                    graph.dndSync.deferMacState(state)
                    // The ring may have stopped meanwhile, after its collector looked.
                    if (!ring.ringing.value) graph.dndSync.applyDeferred()
                } else {
                    graph.dndSync.onMacState(state)
                }
            }
        }
        lifecycleScope.launch {
            // stop() puts the filter back before ringing turns false.
            ring.ringing.drop(1).filter { !it }.collect {
                if (dndSessionNow() != null && graph.dndSyncOn.value) graph.dndSync.applyDeferred() else graph.dndSync.dropDeferred()
            }
        }
        graph.manager.on(MessageType.DND_AVAILABILITY) { env ->
            val availability = DndAvailability.parseFrom(env.payload)
            if (dndSessionNow() != null) graph.dndSync.onMacAvailability(availability)
        }
        lifecycleScope.launch {
            var openSession: Connected? = null
            val availability = DndAvailabilityOnSession { graph.refreshDndAccess(); graph.dndAccess.value }
            combine(
                // By identity: a new session of the same Mac with the same capabilities is still new.
                graph.manager.state
                    .map { s -> (s as? Connected)?.takeIf { "dnd.v1" in it.shared } }
                    .distinctUntilChanged { a, b -> a === b },
                graph.dndSyncOn,
                graph.dndAccess,
            ) { session, on, access -> Triple(session, on, access) }
                .distinctUntilChanged { a, b -> a.first === b.first && a.second == b.second && a.third == b.third }
                .collect { (session, on, access) ->
                    dndSessionNow()
                    if (session != null) {
                        availability.next(session, userOn = on, access = access)?.let {
                            graph.manager.send(Channel.CHANNEL_DND, MessageType.DND_AVAILABILITY, it)
                        }
                    }
                    val open = session != null && on
                    if (!open) {
                        stopDndReceiver()
                        openSession = null
                        return@collect
                    }
                    // Listening first: a change while the baseline is read is not missed.
                    startDndReceiver()
                    if (openSession !== session) {
                        openSession = session
                        try {
                            withContext(Dispatchers.Default) { graph.dndSync.onConnected(sends = true) }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Log.e(TAG, "dnd: start failed (${e.javaClass.simpleName})")
                        }
                    }
                }
        }
    }

    /**
     * Trackpad and remote (F-16): the Mac's `input.availability` says whether it lets this phone move
     * its pointer; kept with its session (cleared when that session ends) and read by
     * [AppGraph.inputOpen]. The phone sends no availability of its own: it needs no permission.
     */
    private fun setUpInput() {
        graph.manager.on(MessageType.INPUT_AVAILABILITY) { env ->
            val availability = FeatureAvailability.parseFrom(env.payload)
            val s = (graph.manager.state.value as? Connected)?.takeIf { "input.v1" in it.shared } ?: return@on
            graph.onMacInputAvailability(s, availability)
            Log.i(TAG, "input: mac availability enabled=${availability.enabled} reason=${availability.reason}")
        }
    }

    /** Registered while the proximity switch is on; touched only on the main thread. */
    private var proximityReceiver: BroadcastReceiver? = null

    /**
     * While the switch is on: the adapter's state (Bluetooth off stops the beacon, on starts every
     * set afresh), and the moments the epoch may have moved without the alarm (ruling R29): the clock or
     * time zone set, the screen coming on, Doze starting or ending (the alarm is then set again,
     * allowed while idle).
     */
    private fun startProximityReceiver() {
        if (proximityReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothAdapter.ACTION_STATE_CHANGED -> {
                        // Marked here, not through the adapter's state flow: a quick off and on can
                        // pass without the flow showing it, and the stack may have dropped the sets.
                        val on = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR) == BluetoothAdapter.STATE_ON
                        if (!on) graph.proximityBeacon.markAdapterNotReady()
                        graph.refreshProximityAdapter()
                        if (on) graph.proximityBeacon.refresh()
                    }
                    else -> graph.proximityBeacon.onClockCheck()
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        }
        // System broadcasts to registered receivers. The adapter's needs no permission from API 31
        // (BLUETOOTH, granted at install, before).
        ContextCompat.registerReceiver(this, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        proximityReceiver = receiver
        // Bluetooth may have changed while nobody listened.
        graph.refreshProximityAdapter()
    }

    private fun stopProximityReceiver() {
        proximityReceiver?.let(::unregisterReceiver)
        proximityReceiver = null
    }

    /**
     * Proximity (F-15): the Bluetooth LE beacon runs while the switch is on, Nearby devices is
     * granted (API 31+) and the adapter can advertise, with one set per Mac [AppGraph.advertisedMacs]
     * lists. It does not depend on the LAN connection: it keeps advertising while a Mac is away.
     * `proximity.availability` goes to the connected Mac while it shares proximity.v1, on connect
     * and on each change, including a fault of that Mac's advertisement.
     */
    private fun setUpProximity() {
        lifecycleScope.launch {
            combine(graph.proximityOn, graph.proximityGranted, graph.proximityAdapter, graph.advertisedMacs) { on, granted, adapter, macs ->
                ProximityInputs(on, granted, adapter, macs)
            }
                .distinctUntilChanged()
                .collect { inputs ->
                    if (inputs.on) startProximityReceiver() else stopProximityReceiver()
                    val active = inputs.on && inputs.granted
                    try {
                        // The fingerprint is read off the main thread (the Keystore); the beacon is fed on
                        // it, so onDestroy's stop always comes last.
                        if (active) graph.warmProximity()
                        graph.proximityBeacon.update(active = active, macs = inputs.macs)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Log.e(TAG, "proximity: update failed (${e.javaClass.simpleName})")
                    }
                }
        }
        lifecycleScope.launch {
            combine(
                // By identity: a new session of the same Mac with the same capabilities is still new.
                graph.manager.state
                    .map { s -> (s as? Connected)?.takeIf { "proximity.v1" in it.shared } }
                    .distinctUntilChanged { a, b -> a === b },
                graph.proximityOn,
                graph.proximityGranted,
                graph.proximityAdapter,
                graph.proximityBeacon.faulted,
            ) { session, on, granted, adapter, faulted ->
                val availability = proximityAvailability(
                    userOn = on, granted = granted, adapter = adapter,
                    faulted = session != null && session.mac.id in faulted,
                )
                session to availability
            }
                .distinctUntilChanged { a, b -> a.first === b.first && a.second == b.second }
                .collect { (session, availability) ->
                    if (session != null) graph.manager.send(Channel.CHANNEL_PROXIMITY, MessageType.PROXIMITY_AVAILABILITY, availability)
                }
        }
    }

    /** Runs one browse request off the main thread, only while [AppGraph.browseOpen]; logs the failure class only. */
    private fun browseRequest(what: String, handle: suspend () -> Unit) {
        graph.scope.launch(Dispatchers.IO) {
            if (!graph.browseOpen()) return@launch
            try {
                handle()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The class only: a message could carry a path.
                Log.e(TAG, "browse: $what failed (${e.javaClass.simpleName})")
            }
        }
    }

    private var screenshotObserver: ContentObserver? = null
    private var screenshotDebounce: Job? = null
    /** Touched only on the main thread (the observer's handler and the state collector). */
    private val screenshotChanges = ChangeDebounce(SCREENSHOT_DEBOUNCE_MS, SCREENSHOT_MAX_WAIT_MS, SystemClock::elapsedRealtime)

    private fun startScreenshotObserver() {
        if (screenshotObserver != null) return
        // Screenshots taken while the feature was closed are not sent now.
        graph.screenshotDetector.reset()
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                val wait = screenshotChanges.onChange()
                screenshotDebounce?.cancel()
                screenshotDebounce = lifecycleScope.launch {
                    delay(wait)
                    screenshotChanges.fired()
                    // On the graph's scope: a later change must not cancel a look already under way.
                    graph.scope.launch(Dispatchers.IO) {
                        try {
                            graph.sendNewScreenshots()
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            // The class only: a message could carry a path.
                            Log.e(TAG, "screenshots: look failed (${e.javaClass.simpleName})")
                        }
                    }
                }
            }
        }
        contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer)
        screenshotObserver = observer
    }

    private fun stopScreenshotObserver() {
        screenshotObserver?.let { contentResolver.unregisterContentObserver(it) }
        screenshotObserver = null
        screenshotDebounce?.cancel()
        screenshotDebounce = null
        screenshotChanges.fired()
    }

    private var contactsObserver: ContentObserver? = null
    private var contactsDebounce: Job? = null

    private fun startContactsObserver() {
        if (contactsObserver != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                contactsDebounce?.cancel()
                contactsDebounce = lifecycleScope.launch {
                    delay(CONTACTS_DEBOUNCE_MS)
                    if (!graph.contactsOpen()) return@launch
                    try {
                        graph.contactsSync.onChanged()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Log.e(TAG, "contacts: push failed", e)
                    }
                }
            }
        }
        contentResolver.registerContentObserver(ContactsContract.Contacts.CONTENT_URI, true, observer)
        contactsObserver = observer
    }

    private fun stopContactsObserver() {
        contactsObserver?.let { contentResolver.unregisterContentObserver(it) }
        contactsObserver = null
        contactsDebounce?.cancel()
        contactsDebounce = null
    }

    private fun onState(state: PhoneConnectionState, macs: List<PairedMac>?, pairing: Boolean) {
        Log.i(TAG, "state: ${state.describe()}")
        graph.keepAliveLog.record(KeepAliveEvent.STATE, state.javaClass.simpleName)
        if (state == PhoneConnectionState.NotPaired) {
            // Started at Confirm, before the pairing saves the Mac: wait for it to finish.
            if (pairing) return
            // The manager starts in NotPaired before it reads the store; only stop once the store
            // agrees no Mac is paired.
            notPairedJob?.cancel()
            notPairedJob = lifecycleScope.launch {
                watchNotPaired(
                    intervalMs = UNREADABLE_RETRY_MS,
                    read = { graph.readPairings() },
                    pairingUnderWay = { graph.pairing.state.value.isUnderWay() },
                    stillNotPaired = { graph.manager.state.value == PhoneConnectionState.NotPaired },
                    kick = { graph.manager.kick() },
                    onUnreadable = { graph.keepAliveLog.record(KeepAliveEvent.STATE, "notpaired-unreadable") },
                    onSelfStop = {
                        graph.keepAliveLog.record(KeepAliveEvent.SERVICE_SELF_STOP, "no-mac")
                        Log.i(TAG, "service: no Mac paired, stopping")
                        ServiceCompat.stopForeground(this@ConnectionService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    },
                )
            }
            return
        }
        // Any other state ends the wait-and-kick loop.
        notPairedJob?.cancel()
        notPairedJob = null
        if (state == PhoneConnectionState.Stopped) return
        val name = state.macOrNull?.name ?: macs?.maxByOrNull { it.lastConnectedAt }?.name
        val text = when {
            state.copyNamesMac() && name != null -> getString(state.messageRes(), name)
            state.copyNamesMac() -> getString(R.string.state_looking_unnamed)
            // Unreachable is still looking; the notification stays short.
            state is PhoneConnectionState.Unreachable && name != null -> getString(R.string.state_looking, name)
            else -> getString(state.messageRes())
        }
        if (text != lastText) {
            lastText = text
            update(text)
        }
    }

    private fun createChannel() {
        val channel = NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
            .setName(getString(R.string.channel_connection))
            .setDescription(getString(R.string.channel_connection_description))
            .setShowBadge(false)
            .build()
        NotificationManagerCompat.from(this).createNotificationChannel(channel)
    }

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        if (clipboardAction) {
            val send = PendingIntent.getActivity(
                this,
                2,
                ClipboardSendActivity.intent(this),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            builder.addAction(0, getString(R.string.notification_send_clipboard), send)
        }
        return builder.build()
    }

    private fun goForeground(text: String) {
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(text), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    private fun update(text: String) {
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (allowed) NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification(text))
    }

    companion object {
        /** How long an unreadable store waits before the manager reads it again. */
        private const val UNREADABLE_RETRY_MS = 30_000L

        const val CHANNEL_ID = "connection"
        private val FILES_TYPES = listOf(
            MessageType.FILES_ENDPOINT, MessageType.FILES_OFFER, MessageType.FILES_ACCEPT, MessageType.FILES_REJECT,
            MessageType.FILES_PROGRESS, MessageType.FILES_COMPLETE, MessageType.FILES_RECEIVED, MessageType.FILES_CANCEL,
            MessageType.FILES_FAILED,
        )
        private const val CONTACTS_DEBOUNCE_MS = 5_000L
        private const val SCREENSHOT_DEBOUNCE_MS = 500L
        private const val SCREENSHOT_MAX_WAIT_MS = 1_500L
        const val ACTION_STOP_RING = "io.github.anmirror.phone.STOP_RING"

        private val _ringing = MutableStateFlow(false)

        /** True while the phone is ringing for find-my-phone; the UI shows a Stop button then. */
        val ringing: StateFlow<Boolean> = _ringing.asStateFlow()

        /** Stops a ring in progress (no-op when the service is not running). */
        fun stopRing(context: Context) {
            if (!running) return
            try {
                context.startService(Intent(context, ConnectionService::class.java).setAction(ACTION_STOP_RING))
            } catch (e: IllegalStateException) {
                Log.w(TAG, "service: stop-ring refused (${e.javaClass.simpleName})")
            }
        }
        private const val NOTIFICATION_ID = 1

        /** True between onCreate and onDestroy. */
        @Volatile var running = false
            private set

        /**
         * Starts the service. Android refuses a foreground service started from the background
         * (ForegroundServiceStartNotAllowedException, an IllegalStateException): that is logged,
         * and MainActivity starts it on its next resume. Returns whether the start was accepted.
         */
        fun start(context: Context): Boolean = try {
            ContextCompat.startForegroundService(context, Intent(context, ConnectionService::class.java))
            true
        } catch (e: IllegalStateException) {
            Log.w(TAG, "service: start refused (${e.javaClass.simpleName})")
            false
        } catch (e: SecurityException) {
            Log.w(TAG, "service: start refused (${e.javaClass.simpleName})")
            false
        }
    }
}

/** What the proximity beacon follows, compared by content ([AppGraph.advertisedMacs] already ignores a new connect time). */
private data class ProximityInputs(
    val on: Boolean,
    val granted: Boolean,
    val adapter: AdvertiserState,
    val macs: List<PairedMac>,
)

/** Pairing is between Continue/scan and its result: the service must not stop meanwhile. */
private fun PairingState.isUnderWay(): Boolean =
    this is PairingState.Connecting || this is PairingState.ShowCode || this is PairingState.WaitingForMac

/** For logs: no discovery key, no addresses. */
private fun PhoneConnectionState.describe(): String = when (this) {
    is PhoneConnectionState.Connected -> "Connected(shared=${shared.sorted().joinToString(",")})"
    else -> this::class.simpleName.orEmpty()
}
