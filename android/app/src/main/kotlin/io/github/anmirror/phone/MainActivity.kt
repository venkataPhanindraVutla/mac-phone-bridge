package io.github.anmirror.phone

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.anmirror.phone.remote.TrackpadActivity
import io.github.anmirror.phone.diag.KeepAliveEvent
import io.github.anmirror.phone.service.BootDecision
import io.github.anmirror.phone.service.ServiceProbe
import io.github.anmirror.phone.service.ConnectionService
import io.github.anmirror.phone.ui.ConfirmCodeScreen
import io.github.anmirror.phone.ui.HomeScreen
import io.github.anmirror.phone.ui.KeepConnectedScreen
import io.github.anmirror.phone.ui.LinkOfferScreen
import io.github.anmirror.phone.ui.OnboardingScreen
import io.github.anmirror.phone.ui.ScanScreen
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private lateinit var graph: AppGraph

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        graph = AppGraph.get(this)
        if (savedInstanceState == null) takeLink(intent)
        setContent { AppTheme { AppRoot(graph) } }
    }

    override fun onResume() {
        super.onResume()
        // Back from Settings: re-read notification access.
        graph.refreshNotifyAccess()
        graph.refreshContactsGranted()
        graph.refreshCallsPermissions()
        graph.refreshMediaAccess()
        graph.refreshDndAccess()
        graph.refreshProximityGranted()
        graph.refreshProximityAdapter()
        // Back from the exemption dialog or Settings; the Mac hears of a change through the status.
        graph.refreshBackgroundExempt()
        graph.launchQuietly("browse: access refresh") { graph.refreshBrowseAccess() }
        // Opening the app is a way to silence a ring, also when notifications are blocked.
        if (ConnectionService.ringing.value) ConnectionService.stopRing(this)
        // Bring the service up whenever a Mac is paired. The `running` flag is not trusted: it
        // goes stale when the system kills the service. Starting a running service only re-runs
        // onStartCommand, which is harmless.
        graph.scope.launch {
            graph.keepAliveLog.record(
                KeepAliveEvent.APP_OPEN,
                "flag=${ConnectionService.running} probe=${ServiceProbe.connectionServiceRunning(this@MainActivity)}",
            )
            if (BootDecision.shouldStart(confirmedEmpty = graph.noMacPaired())) {
                runOnUiThread { ConnectionService.start(this@MainActivity) }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        takeLink(intent)
    }

    /** An `anmirror://pair` link only offers pairing; nothing is dialed before Continue. */
    private fun takeLink(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW || intent.data?.scheme != "anmirror") return
        intent.dataString?.let(graph.pairing::offerLink)
    }
}

private enum class Screen { Main, Scan, KeepConnected }

/** The store could not be read just now; nothing was forgotten. */
private suspend fun forgetFailed(context: android.content.Context) = withContext(Dispatchers.Main) {
    android.widget.Toast.makeText(context, R.string.forget_failed, android.widget.Toast.LENGTH_LONG).show()
}

@Composable
private fun AppRoot(graph: AppGraph) {
    val macs by graph.store.macs.collectAsStateWithLifecycle()
    val pairing by graph.pairing.state.collectAsStateWithLifecycle()
    val connection by graph.manager.state.collectAsStateWithLifecycle()
    val ringing by ConnectionService.ringing.collectAsStateWithLifecycle()
    val notifyOn by graph.notifyOn.collectAsStateWithLifecycle()
    val notifyAccess by graph.notifyAccess.collectAsStateWithLifecycle()
    val mediaControlOn by graph.mediaControlOn.collectAsStateWithLifecycle()
    val dndSyncOn by graph.dndSyncOn.collectAsStateWithLifecycle()
    val dndAccess by graph.dndAccess.collectAsStateWithLifecycle()
    val macDnd by graph.dndSync.macAvailability.collectAsStateWithLifecycle()
    val proximityOn by graph.proximityOn.collectAsStateWithLifecycle()
    val proximityGranted by graph.proximityGranted.collectAsStateWithLifecycle()
    val proximityAdapter by graph.proximityAdapter.collectAsStateWithLifecycle()
    val macInput by graph.macInputAvailability.collectAsStateWithLifecycle()
    val contactsOn by graph.contactsOn.collectAsStateWithLifecycle()
    val contactsGranted by graph.contactsGranted.collectAsStateWithLifecycle()
    val callsOn by graph.callsOn.collectAsStateWithLifecycle()
    val callsPermissions by graph.callsPermissions.collectAsStateWithLifecycle()
    val clipboardOn by graph.clipboardOn.collectAsStateWithLifecycle()
    val screenshotsOn by graph.screenshotsOn.collectAsStateWithLifecycle()
    val mediaAccess by graph.mediaAccess.collectAsStateWithLifecycle()
    val photosOn by graph.photosOn.collectAsStateWithLifecycle()
    val photosAccess by graph.photosAccess.collectAsStateWithLifecycle()
    val browseOn by graph.browseOn.collectAsStateWithLifecycle()
    val allFilesAccess by graph.allFilesAccess.collectAsStateWithLifecycle()
    val pickedFolders by graph.pickedFolders.folders.collectAsStateWithLifecycle()
    val backgroundExempt by graph.backgroundExempt.collectAsStateWithLifecycle()
    val makerStepDone by graph.makerStepDone.collectAsStateWithLifecycle()
    val background = BackgroundState(backgroundExempt, graph.maker, makerStepDone)
    val context = LocalContext.current
    var screen by rememberSaveable { mutableStateOf(Screen.Main) }

    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        when (val p = pairing) {
            is PairingState.LinkOffer -> LinkOfferScreen(
                offer = p,
                onContinue = graph.pairing::acceptLink,
                onCancel = graph.pairing::cancel,
            )
            PairingState.Idle -> when {
                screen == Screen.Scan -> {
                    BackHandler { screen = Screen.Main }
                    ScanScreen(onCode = graph.pairing::pair, onBack = { screen = Screen.Main })
                }
                screen == Screen.KeepConnected -> KeepConnectedScreen(
                    state = background,
                    onDone = {
                        if (background.maker != null) graph.setMakerStepDone()
                        screen = Screen.Main
                    },
                    onNotNow = { screen = Screen.Main },
                )
                macs == null -> Unit // the store is loading; a blank frame, no flash of onboarding
                macs.orEmpty().isEmpty() -> OnboardingScreen(onPair = { screen = Screen.Scan })
                else -> {
                    val mac = macs.orEmpty().maxBy { it.lastConnectedAt }
                    HomeScreen(
                        mac = mac,
                        state = connection,
                        ringing = ringing,
                        onStopRing = { ConnectionService.stopRing(context) },
                        onRetry = graph.manager::kick,
                        keepPrompt = background.showsPrompt,
                        onKeepFix = { screen = Screen.KeepConnected },
                        notifyOn = notifyOn,
                        notifyAccess = notifyAccess,
                        onNotifyToggle = graph::setNotifyOn,
                        mediaControlOn = mediaControlOn,
                        onMediaControlToggle = graph::setMediaControlOn,
                        dndSyncOn = dndSyncOn,
                        dndAccess = dndAccess,
                        macDnd = macDnd,
                        onDndSyncToggle = graph::setDndSyncOn,
                        proximityOn = proximityOn,
                        proximityGranted = proximityGranted,
                        proximityAdapter = proximityAdapter,
                        onProximityToggle = graph::setProximityOn,
                        onProximityPermissionResult = graph::refreshProximityGranted,
                        trackpadShown = inputShared(connection),
                        trackpadOpen = inputOpen(connection, macInput),
                        trackpadLine = trackpadLine(connection, macInput),
                        onOpenTrackpad = { context.startActivity(Intent(context, TrackpadActivity::class.java)) },
                        contactsOn = contactsOn,
                        contactsGranted = contactsGranted,
                        onContactsToggle = graph::setContactsOn,
                        onContactsPermissionResult = graph::refreshContactsGranted,
                        callsOn = callsOn,
                        callsGranted = callsPermissions.phoneState,
                        onCallsToggle = graph::setCallsOn,
                        onCallsPermissionResult = graph::refreshCallsPermissions,
                        clipboardOn = clipboardOn,
                        onClipboardToggle = graph::setClipboardOn,
                        screenshotsOn = screenshotsOn,
                        mediaAccess = mediaAccess,
                        onScreenshotsToggle = graph::setScreenshotsOn,
                        onMediaPermissionResult = graph::refreshMediaAccess,
                        photosOn = photosOn,
                        photosAccess = photosAccess,
                        onPhotosToggle = graph::setPhotosOn,
                        browseOn = browseOn,
                        allFilesOffered = graph.allFilesOffered(),
                        allFilesAccess = allFilesAccess,
                        pickedFolders = pickedFolders,
                        onBrowseToggle = graph::setBrowseOn,
                        // The grant and the folder's name come from the provider: off the main thread.
                        onFolderPicked = { uri -> graph.launchQuietly("browse: add folder") { graph.pickedFolders.add(uri) } },
                        onRemoveFolder = { folder -> graph.launchQuietly("browse: remove folder") { graph.pickedFolders.remove(folder.root.id) } },
                        onForget = { graph.scope.launch { if (!graph.manager.forget(mac.id)) forgetFailed(context) } },
                        onPairAgain = {
                            graph.scope.launch {
                                if (graph.manager.forget(mac.id)) {
                                    withContext(Dispatchers.Main) { screen = Screen.Scan }
                                } else {
                                    forgetFailed(context)
                                }
                            }
                        },
                    )
                }
            }
            else -> ConfirmCodeScreen(
                state = p,
                onConfirm = graph.pairing::confirm,
                onCancel = graph.pairing::cancel,
                onDone = {
                    // Continue after a new pairing goes through the keep-connected step if it is left.
                    val paired = p is PairingState.Paired
                    graph.pairing.dismiss()
                    screen = if (paired && background.showsPrompt) Screen.KeepConnected else Screen.Main
                },
                onRetry = {
                    graph.pairing.dismiss()
                    screen = Screen.Scan
                },
            )
        }
    }
}

@Composable
internal fun AppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}
