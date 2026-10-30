package io.github.anmirror.phone.ui

import android.content.Context
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.anmirror.phone.BackgroundState
import io.github.anmirror.phone.Maker
import io.github.anmirror.phone.R
import io.github.anmirror.phone.platform.Battery

/**
 * "Stay connected when the phone is locked": after pairing (when [BackgroundState.showsPrompt])
 * and from the home row's Fix. Allow opens Android's exemption dialog and goes away once the app
 * is exempt; the maker's own step is shown only on phones known to need one, and only the user
 * can say it is done.
 */
@Composable
fun KeepConnectedScreen(state: BackgroundState, onDone: () -> Unit, onNotNow: () -> Unit) {
    val context = LocalContext.current
    BackHandler(onBack = onNotNow)
    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Spacer(Modifier.padding(top = 32.dp))
        Text(
            stringResource(R.string.keep_title),
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() },
        )
        Text(stringResource(R.string.keep_body), style = MaterialTheme.typography.bodyLarge)
        if (!state.exempt) {
            Button(onClick = { context.toastUnlessOpened(Battery.openExemption(context)) }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.keep_allow))
            }
        }
        state.maker?.let { maker ->
            Text(stringResource(R.string.keep_maker_intro), style = MaterialTheme.typography.bodyLarge)
            Text(stringResource(maker.lineRes()), style = MaterialTheme.typography.bodyLarge)
            maker.fallbackRes()?.let { Text(stringResource(it), style = MaterialTheme.typography.bodyMedium) }
            OutlinedButton(onClick = { context.toastUnlessOpened(Battery.openAppSettings(context)) }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.keep_open_settings))
            }
        }
        Spacer(Modifier.weight(1f))
        Button(onClick = onDone, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.keep_done)) }
        TextButton(onClick = onNotNow, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.keep_not_now)) }
    }
}

/** The maker's own battery setting. Only the vivo path has been checked on a real phone. */
internal fun Maker.lineRes(): Int = when (this) {
    Maker.VIVO -> R.string.keep_maker_vivo
    Maker.XIAOMI -> R.string.keep_maker_xiaomi
    Maker.OPPO -> R.string.keep_maker_oppo
    Maker.SAMSUNG -> R.string.keep_maker_samsung
    Maker.HUAWEI -> R.string.keep_maker_huawei
}

/** Where the setting is on the maker's other builds, if it moves. */
internal fun Maker.fallbackRes(): Int? = when (this) {
    Maker.VIVO -> R.string.keep_maker_vivo_fallback
    else -> null
}

/** Settings could not be opened at all: say so instead of doing nothing. */
private fun Context.toastUnlessOpened(opened: Boolean) {
    if (!opened) Toast.makeText(this, R.string.keep_settings_unavailable, Toast.LENGTH_SHORT).show()
}
