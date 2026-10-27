package io.github.anmirror.phone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PhoneConnectionState
import io.github.anmirror.phone.R
import io.github.anmirror.phone.copyNamesMac
import io.github.anmirror.phone.messageRes

/** The paired Mac, the connection state from ConnectionManager, and Forget this Mac. */
@Composable
fun HomeScreen(
    mac: PairedMac,
    state: PhoneConnectionState,
    onRetry: () -> Unit,
    onForget: () -> Unit,
    onPairAgain: () -> Unit,
) {
    var confirmForget by rememberSaveable { mutableStateOf(false) }
    var confirmPairAgain by rememberSaveable { mutableStateOf(false) }
    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            stringResource(R.string.home_title),
            style = MaterialTheme.typography.labelLarge,
        )
        Text(
            mac.name,
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() },
        )
        val text = if (state.copyNamesMac()) stringResource(state.messageRes(), mac.name) else stringResource(state.messageRes())
        Text(
            text,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
        if (state is PhoneConnectionState.NotRecognized) {
            // The Mac forgot this phone: the way back is a new pairing.
            Button(onClick = { confirmPairAgain = true }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.home_pair_again))
            }
        } else if (state !is PhoneConnectionState.Connected) {
            Button(onClick = onRetry, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.home_retry)) }
        }
        Spacer(Modifier.weight(1f))
        OutlinedButton(onClick = { confirmForget = true }, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.home_forget))
        }
    }
    if (confirmPairAgain) {
        AlertDialog(
            onDismissRequest = { confirmPairAgain = false },
            title = { Text(stringResource(R.string.home_pair_again_title)) },
            text = { Text(stringResource(R.string.home_pair_again_body, mac.name)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmPairAgain = false
                    onPairAgain()
                }) { Text(stringResource(R.string.home_pair_again)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmPairAgain = false }) { Text(stringResource(R.string.pair_cancel)) }
            },
        )
    }
    if (confirmForget) {
        AlertDialog(
            onDismissRequest = { confirmForget = false },
            title = { Text(stringResource(R.string.home_forget_title, mac.name)) },
            text = { Text(stringResource(R.string.home_forget_body)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmForget = false
                    onForget()
                }) { Text(stringResource(R.string.home_forget_confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmForget = false }) { Text(stringResource(R.string.pair_cancel)) }
            },
        )
    }
}
