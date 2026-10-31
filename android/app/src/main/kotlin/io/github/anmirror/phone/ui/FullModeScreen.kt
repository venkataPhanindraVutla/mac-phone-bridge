package io.github.anmirror.phone.ui

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import io.github.anmirror.feature.mirror.MakerGuidance
import io.github.anmirror.feature.mirror.SetupState
import io.github.anmirror.phone.R
import io.github.anmirror.phone.pairingErrorRes
import io.github.anmirror.phone.service.NotificationPermission
import io.github.anmirror.phone.service.PairingInput
import io.github.anmirror.phone.service.PairingNotifications
import io.github.anmirror.phone.service.pairingInput
import io.github.anmirror.phone.statusRes

/**
 * "Full mode": what it is, the steps to Wireless debugging's pairing screen, and the pairing
 * itself (the code goes into the notification "Start pairing" posts). When connecting fails, the
 * port shown under Wireless debugging can be typed in.
 */
@Composable
fun FullModeScreen(
    state: SetupState,
    maker: MakerGuidance,
    pairingPort: Int?,
    onStartPairing: () -> Unit,
    onPairInApp: (port: String, code: String) -> Unit,
    onConnect: (port: Int) -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    BackHandler(onBack = onBack)
    val needed = fullModePairingPermissions()
    // The code goes into a notification while it can show; otherwise into this screen (R50). A
    // refusal is remembered for the screen: asking again after a permanent one shows nothing.
    var refused by rememberSaveable { mutableStateOf(false) }
    fun readInput() = pairingInput(
        permission = when {
            PairingNotifications.permitted(context) -> NotificationPermission.GRANTED
            refused -> NotificationPermission.DENIED
            else -> NotificationPermission.ASKABLE
        },
        appNotificationsOn = PairingNotifications.appNotificationsOn(context),
        channelOn = PairingNotifications.channelOn(context),
    )
    var input by remember { mutableStateOf(readInput()) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { input = readInput() }
    val start by rememberUpdatedState(onStartPairing)
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        refused = !granted
        input = readInput()
        start() // by notification, or in this screen when refused
    }
    var pairingPortText by rememberSaveable { mutableStateOf("") }
    var pairingCode by rememberSaveable { mutableStateOf("") }
    LaunchedEffect(state) {
        // Prefill the port NSD found, unless one was typed already.
        if (state is SetupState.Pairing && pairingPortText.isEmpty()) pairingPort?.let { pairingPortText = it.toString() }
    }
    // The typed port stays offered from the first failed connect until the setup is ready.
    var portOffered by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(state) {
        if (state == SetupState.ConnectFailed) portOffered = true
        if (state == SetupState.Ready || state == SetupState.Unpaired) portOffered = false
    }
    var port by rememberSaveable { mutableStateOf("") }
    val typedPort = port.toIntOrNull()?.takeIf { it in 1..MAX_PORT }

    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            stringResource(R.string.full_title),
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() },
        )
        for (intro in listOf(R.string.full_intro_1, R.string.full_intro_2, R.string.full_intro_3)) {
            Text(stringResource(intro), style = MaterialTheme.typography.bodyLarge)
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(R.string.full_step_1, R.string.full_step_2, R.string.full_step_3, R.string.full_step_4).forEachIndexed { i, step ->
                Text("${i + 1}. ${stringResource(step)}", style = MaterialTheme.typography.bodyLarge)
            }
        }
        maker.lineRes()?.let { Text(stringResource(it), style = MaterialTheme.typography.bodyLarge) }
        // The buttons' own text is their TalkBack label.
        OutlinedButton(onClick = { context.openDeveloperOptions() }, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.full_open_developer_options))
        }
        Button(
            onClick = {
                when (input) {
                    PairingInput.ASK_PERMISSION -> if (needed.isNotEmpty()) ask.launch(needed.first()) else onStartPairing()
                    PairingInput.NOTIFICATION, PairingInput.IN_APP -> onStartPairing()
                }
            },
            // Also while waiting for the code: the pairing screen may have been closed, or the notification swiped away.
            enabled = state != SetupState.Looking && state != SetupState.Connecting,
            modifier = Modifier.fillMaxWidth(),
        ) { Text(stringResource(R.string.full_start_pairing)) }
        if (input == PairingInput.ASK_PERMISSION) {
            Text(stringResource(R.string.full_notifications_needed), style = MaterialTheme.typography.bodyMedium)
        }
        val waitingForCode = state is SetupState.Pairing || state is SetupState.PairFailed
        if (input == PairingInput.IN_APP && waitingForCode) {
            // The notification's own words, then its two inputs.
            val portKnown = pairingPort != null
            Text(
                stringResource(if (portKnown) R.string.pairing_notification_text_code else R.string.pairing_notification_text_port_and_code),
                style = MaterialTheme.typography.bodyLarge,
            )
            OutlinedTextField(
                value = pairingPortText,
                onValueChange = { typed -> pairingPortText = typed.filter { it in '0'..'9' }.take(PORT_DIGITS) },
                label = { Text(stringResource(R.string.full_pairing_port)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )
            val pair = { onPairInApp(pairingPortText, pairingCode) }
            OutlinedTextField(
                value = pairingCode,
                onValueChange = { typed -> pairingCode = typed.filter { it in '0'..'9' }.take(CODE_DIGITS) },
                label = { Text(stringResource(R.string.pairing_notification_input_code)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { pair() }),
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = { pair() },
                // The setup checks the fields (INVALID otherwise); here only an obviously short code waits.
                enabled = pairingCode.length == CODE_DIGITS,
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.full_pair)) }
        }
        state.statusRes()?.let { status ->
            Text(
                stringResource(status),
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        val error = when (state) {
            is SetupState.PairFailed -> pairingErrorRes(state.error)
            SetupState.ConnectFailed -> R.string.full_connect_failed
            else -> null
        }
        error?.let {
            Text(
                stringResource(it),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        if (portOffered) {
            val connect = { typedPort?.let(onConnect) }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                OutlinedTextField(
                    value = port,
                    onValueChange = { typed -> port = typed.filter { it in '0'..'9' }.take(PORT_DIGITS) },
                    label = { Text(stringResource(R.string.full_connection_port)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { connect() }),
                    modifier = Modifier.weight(1f),
                )
                Button(
                    onClick = { connect() },
                    enabled = typedPort != null && state != SetupState.Connecting,
                ) { Text(stringResource(R.string.full_connect)) }
            }
        }
        Spacer(Modifier.padding(bottom = 16.dp))
    }
}

/** The maker's extra Developer options switch for taps and typing, if this phone needs one. */
internal fun MakerGuidance.lineRes(): Int? = when (this) {
    MakerGuidance.USB_DEBUGGING_SECURITY -> R.string.full_maker_xiaomi
    MakerGuidance.DISABLE_PERMISSION_MONITORING -> R.string.full_maker_bbk
    MakerGuidance.NONE -> null
}

private const val MAX_PORT = 65_535
private const val PORT_DIGITS = 5
private const val CODE_DIGITS = 6
