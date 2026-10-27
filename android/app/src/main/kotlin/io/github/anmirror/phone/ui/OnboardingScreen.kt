package io.github.anmirror.phone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.anmirror.phone.R

/** What the app does, that nothing leaves the two devices, and the way into pairing. */
@Composable
fun OnboardingScreen(onPair: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Spacer(Modifier.padding(top = 32.dp))
        Text(
            stringResource(R.string.onboarding_title),
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() },
        )
        Text(stringResource(R.string.onboarding_body), style = MaterialTheme.typography.bodyLarge)
        Text(stringResource(R.string.onboarding_privacy), style = MaterialTheme.typography.bodyLarge)
        Spacer(Modifier.weight(1f))
        Button(onClick = onPair, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.onboarding_pair)) }
    }
}
