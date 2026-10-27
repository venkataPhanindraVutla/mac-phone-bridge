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
import io.github.anmirror.phone.ui.OnboardingScreen
import io.github.anmirror.phone.ui.ScanScreen
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private lateinit var graph: AppGraph

    /** An `anmirror://pair?...` link waiting for its permissions before pairing starts. */
    private val linked = MutableStateFlow<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        graph = AppGraph.get(this)
        if (savedInstanceState == null) takeLink(intent)
        // Bring the service up if a Mac is paired (after a force stop, say).
        graph.scope.launch {
            if (BootDecision.shouldStartService(graph.store.all().size)) runOnUiThread { ConnectionService.start(this@MainActivity) }
        }
        setContent { AppTheme { AppRoot(graph, linked) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        takeLink(intent)
    }

    private fun takeLink(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val data = intent.dataString ?: return
        if (intent.data?.scheme == "anmirror") linked.value = data
    }
}

private enum class Screen { Main, Scan }

@Composable
private fun AppRoot(graph: AppGraph, linked: MutableStateFlow<String?>) {
    val macs by graph.store.macs.collectAsStateWithLifecycle()
    val pairing by graph.pairing.state.collectAsStateWithLifecycle()
    val connection by graph.manager.state.collectAsStateWithLifecycle()
    val link by linked.collectAsStateWithLifecycle()
    var screen by rememberSaveable { mutableStateOf(Screen.Main) }

    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        when {
            // A link pairs without the camera, but still asks for notifications and local network.
            link != null -> ScanScreen(
                needsCamera = false,
                onCode = { code ->
                    linked.value = null
                    graph.pairing.pair(code)
                },
                onBack = { linked.value = null },
                autoStart = true,
                initialCode = link,
            )
            pairing != PairingState.Idle -> ConfirmCodeScreen(
                state = pairing,
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
            screen == Screen.Scan -> {
                BackHandler { screen = Screen.Main }
                ScanScreen(
                    needsCamera = true,
                    onCode = { code -> graph.pairing.pair(code) },
                    onBack = { screen = Screen.Main },
                )
            }
            macs == null -> Unit // the store is loading; a blank frame, no flash of onboarding
            macs.orEmpty().isEmpty() -> OnboardingScreen(onPair = { screen = Screen.Scan })
            else -> {
                val mac = macs.orEmpty().maxBy { it.lastConnectedAt }
                HomeScreen(
                    mac = mac,
                    state = connection,
                    onRetry = graph.manager::kick,
                    onForget = { graph.scope.launch { graph.manager.forget(mac.id) } },
                )
            }
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
