package io.github.anmirror.phone.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.anmirror.phone.PairingState
import io.github.anmirror.phone.R
import io.github.anmirror.phone.messageRes

/** Pairing after the scan: connecting, the 6-digit code with Confirm / Cancel, then the result. */
@Composable
fun ConfirmCodeScreen(
    state: PairingState,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
    onDone: () -> Unit,
    onRetry: () -> Unit,
) {
    BackHandler {
        when (state) {
            is PairingState.Connecting, is PairingState.ShowCode, is PairingState.WaitingForMac -> onCancel()
            else -> onDone()
        }
    }
    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        when (state) {
            is PairingState.Connecting -> Progress(stringResource(R.string.pair_connecting, state.macName), onCancel)
            is PairingState.WaitingForMac -> Progress(stringResource(R.string.pair_waiting_for_mac), onCancel)
            is PairingState.ShowCode -> {
                Text(
                    stringResource(R.string.pair_code_title),
                    style = MaterialTheme.typography.headlineMedium,
                    modifier = Modifier.semantics { heading() },
                )
                // Read digit by digit, not as one six-digit number.
                val spoken = stringResource(R.string.pair_code_description, state.code.toList().joinToString(" "))
                Text(
                    state.code.chunked(3).joinToString(" "),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 48.sp,
                    modifier = Modifier.align(Alignment.CenterHorizontally).clearAndSetSemantics { contentDescription = spoken },
                )
                Text(stringResource(R.string.pair_code_hint), style = MaterialTheme.typography.bodyLarge)
                state.switchesFrom?.let { Text(stringResource(R.string.pair_switches_from, it), style = MaterialTheme.typography.bodyLarge) }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                    OutlinedButton(onClick = onCancel, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.pair_cancel)) }
                    Button(onClick = onConfirm, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.pair_confirm)) }
                }
            }
            is PairingState.Paired -> {
                Result(stringResource(R.string.pair_done, state.macName))
                Button(onClick = onDone, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_continue)) }
            }
            is PairingState.Failed -> {
                Result(stringResource(state.failure.messageRes()))
                Button(onClick = onRetry, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_try_again)) }
                OutlinedButton(onClick = onDone, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_cancel)) }
            }
            PairingState.NotACode -> {
                Result(stringResource(R.string.pair_bad_code))
                Button(onClick = onRetry, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_try_again)) }
                OutlinedButton(onClick = onDone, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_cancel)) }
            }
            PairingState.Idle, is PairingState.LinkOffer -> Unit
        }
    }
}

@Composable
private fun Progress(text: String, onCancel: () -> Unit) {
    CircularProgressIndicator()
    Text(text, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
    OutlinedButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_cancel)) }
}

@Composable
private fun Result(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.headlineSmall,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}
