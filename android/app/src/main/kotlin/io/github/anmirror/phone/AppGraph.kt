package io.github.anmirror.phone

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.AtomicFile
import android.util.Log
import io.github.anmirror.connection.ConnectionManager
import io.github.anmirror.connection.PROTOCOL_VERSION
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PairedMacStore
import io.github.anmirror.connection.PhonePairingClient
import io.github.anmirror.connection.TlsConnector
import io.github.anmirror.connection.TlsIdentity
import io.github.anmirror.phone.platform.AndroidKeystoreIdentity
import io.github.anmirror.phone.platform.EncryptedPairedMacStore
import io.github.anmirror.phone.platform.KeystoreCipher
import io.github.anmirror.phone.platform.NsdMacDiscovery
import io.github.anmirror.phone.service.ConnectionService
import io.github.anmirror.protocol.v1.Hello
import io.github.anmirror.protocol.v1.SetupLevel
import kotlinx.coroutines.CoroutineExceptionHandler
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

    init {
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
        val CAPABILITIES = listOf("status.v1", "find.v1")

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
