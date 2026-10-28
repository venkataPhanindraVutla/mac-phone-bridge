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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.anmirror.phone.PairingState
import io.github.anmirror.phone.R

/**
 * An `anmirror://pair` link opened the app (any web page can do that). Nothing is dialed until
 * Continue (ruling R27). Continue asks for notifications and local network (37+), not the camera.
 */
@Composable
fun LinkOfferScreen(offer: PairingState.LinkOffer, onContinue: () -> Unit, onCancel: () -> Unit) {
    BackHandler(onBack = onCancel)
    val permissions = remember { pairingPermissions(needsCamera = false) }
    val (chain, asking) = rememberPermissionChain(permissions, onContinue)
    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            stringResource(R.string.pair_link_title, offer.macName),
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() },
        )
        val rationale = permissionRationale(asking)
        Text(
            if (rationale != null) stringResource(rationale) else stringResource(R.string.pair_link_body, offer.macName),
            style = MaterialTheme.typography.bodyLarge,
        )
        offer.switchesFrom?.let { Text(stringResource(R.string.pair_switches_from, it), style = MaterialTheme.typography.bodyLarge) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(onClick = onCancel, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.pair_cancel)) }
            Button(onClick = chain::start, modifier = Modifier.weight(1f)) { Text(stringResource(R.string.pair_link_continue)) }
        }
    }
}
