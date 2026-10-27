package io.github.anmirror.phone.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import io.github.anmirror.phone.R

/**
 * Pairing's first step. Asks for permissions in order (notifications, camera, then local
 * network on Android 17+), each just before it is needed, then scans the Mac's QR code.
 */
@Composable
fun ScanScreen(onCode: (String) -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val prompt = stringResource(R.string.pair_scan_prompt)
    var cameraDenied by rememberSaveable { mutableStateOf(false) }
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result -> result.contents?.let(onCode) }
    val permissions = remember { pairingPermissions(needsCamera = true) }
    val (chain, asking) = rememberPermissionChain(permissions) {
        if (!context.isGranted(Manifest.permission.CAMERA)) {
            cameraDenied = true
        } else {
            scanner.launch(
                ScanOptions()
                    .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                    .setPrompt(prompt)
                    .setBeepEnabled(false)
                    .setOrientationLocked(false),
            )
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            stringResource(R.string.pair_title),
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() },
        )
        val body = when {
            cameraDenied -> R.string.pair_camera_denied
            else -> permissionRationale(asking) ?: R.string.pair_instructions
        }
        Text(stringResource(body), style = MaterialTheme.typography.bodyLarge)
        Button(
            onClick = {
                cameraDenied = false
                chain.start()
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text(stringResource(R.string.pair_scan)) }
        TextButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_cancel)) }
    }
}
