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
import io.github.anmirror.phone.service.BootDecision
import io.github.anmirror.phone.service.ConnectionService
import io.github.anmirror.phone.ui.ConfirmCodeScreen
import io.github.anmirror.phone.ui.HomeScreen
import io.github.anmirror.phone.ui.LinkOfferScreen
import io.github.anmirror.phone.ui.OnboardingScreen
import io.github.anmirror.phone.ui.ScanScreen
import kotlinx.coroutines.launch

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
        // Opening the app is a way to silence a ring, also when notifications are blocked.
        if (ConnectionService.ringing.value) ConnectionService.stopRing(this)
        // Bring the service up if a Mac is paired and it isn't running (after a force stop, or
        // when a start from the background was refused).
        graph.scope.launch {
            if (!ConnectionService.running && BootDecision.shouldStartService(graph.store.all().size)) {
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

private enum class Screen { Main, Scan }

@Composable
private fun AppRoot(graph: AppGraph) {
    val macs by graph.store.macs.collectAsStateWithLifecycle()
    val pairing by graph.pairing.state.collectAsStateWithLifecycle()
    val connection by graph.manager.state.collectAsStateWithLifecycle()
    val ringing by ConnectionService.ringing.collectAsStateWithLifecycle()
    val notifyOn by graph.notifyOn.collectAsStateWithLifecycle()
    val notifyAccess by graph.notifyAccess.collectAsStateWithLifecycle()
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
                        notifyOn = notifyOn,
                        notifyAccess = notifyAccess,
                        onNotifyToggle = graph::setNotifyOn,
                        onForget = { graph.scope.launch { graph.manager.forget(mac.id) } },
                        onPairAgain = {
                            graph.scope.launch { graph.manager.forget(mac.id) }
                            screen = Screen.Scan
                        },
                    )
                }
            }
            else -> ConfirmCodeScreen(
                state = p,
                onConfirm = graph.pairing::confirm,
                onCancel = graph.pairing::cancel,
                onDone = {
                    graph.pairing.dismiss()
                    screen = Screen.Main
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
private fun AppTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}
