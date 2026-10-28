package io.github.anmirror.phone

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.AtomicFile
import android.util.Log
import com.google.protobuf.MessageLite
import androidx.core.app.NotificationManagerCompat
import io.github.anmirror.connection.ConnectionManager
import io.github.anmirror.connection.PhoneConnectionState
import io.github.anmirror.connection.PROTOCOL_VERSION
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PairedMacStore
import io.github.anmirror.connection.PhonePairingClient
import io.github.anmirror.connection.TlsConnector
import io.github.anmirror.connection.TlsIdentity
import io.github.anmirror.feature.contacts.AndroidContactsSource
import io.github.anmirror.feature.contacts.ContactsSync
import io.github.anmirror.feature.notify.ActionInvoker
import io.github.anmirror.feature.notify.NotificationSnapshot
import io.github.anmirror.feature.notify.NotifyBridge
import io.github.anmirror.phone.platform.AndroidKeystoreIdentity
import io.github.anmirror.phone.platform.EncryptedPairedMacStore
import io.github.anmirror.phone.platform.KeystoreCipher
import io.github.anmirror.phone.platform.NsdMacDiscovery
import io.github.anmirror.phone.ui.isGranted
import io.github.anmirror.phone.service.ConnectionService
import io.github.anmirror.protocol.v1.ActionOutcome
import io.github.anmirror.protocol.v1.Channel as ProtoChannel
import io.github.anmirror.protocol.v1.Hello
import io.github.anmirror.protocol.v1.SetupLevel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

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

    /** This connection's handshake state (R7). Used only from the ordered event queue. */
    val notifySession = NotifySession { notifyBridge.onConnected() }

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
        val CAPABILITIES = listOf("status.v1", "find.v1", "notify.v1", "contacts.v1")
        private const val KEY_NOTIFY_ON = "show_on_mac"
        private const val KEY_CONTACTS_ON = "share_with_mac"

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
    override fun active(): List<NotificationSnapshot> = target?.active().orEmpty()
    override fun image(key: String): ByteArray? = target?.image(key)
    override fun icon(packageName: String): ByteArray? = target?.icon(packageName)
}
