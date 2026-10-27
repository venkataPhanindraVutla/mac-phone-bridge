package io.github.anmirror.phone.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.runtime.LaunchedEffect
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
import androidx.core.content.ContextCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import io.github.anmirror.phone.R

/**
 * Pairing's first step. Asks for permissions in order (notifications, camera, then local
 * network on Android 17+), each just before it is needed, then scans the Mac's QR code.
 *
 * With [needsCamera] false (an `anmirror://pair` link opened the app), it asks only for
 * notifications and local network, then hands over [initialCode].
 */
@Composable
fun ScanScreen(
    needsCamera: Boolean,
    onCode: (String) -> Unit,
    onBack: () -> Unit,
    autoStart: Boolean = false,
    initialCode: String? = null,
) {
    val context = LocalContext.current
    val prompt = stringResource(R.string.pair_scan_prompt)
    val permissions = remember(needsCamera) { pairingPermissions(needsCamera) }
    /** The permission being asked for, to explain it while the system dialog shows. */
    var asking by rememberSaveable { mutableStateOf<String?>(null) }
    var cameraDenied by rememberSaveable { mutableStateOf(false) }

    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let(onCode)
    }

    fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED

    fun finish() {
        asking = null
        if (!needsCamera) {
            initialCode?.let(onCode)
            return
        }
        if (!granted(Manifest.permission.CAMERA)) {
            cameraDenied = true
            return
        }
        scanner.launch(
            ScanOptions()
                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setPrompt(prompt)
                .setBeepEnabled(false)
                .setOrientationLocked(false),
        )
    }

    lateinit var next: () -> Unit
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { next() }
    var position by rememberSaveable { mutableStateOf(0) }
    next = {
        // Ask for each missing permission in turn; a denial moves on (only the camera is required).
        while (position < permissions.size && granted(permissions[position])) position++
        if (position < permissions.size) {
            val p = permissions[position++]
            asking = p
            request.launch(p)
        } else {
            finish()
        }
    }

    fun start() {
        cameraDenied = false
        position = 0
        next()
    }

    if (autoStart) LaunchedEffect(initialCode) { start() }

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
            asking == Manifest.permission.POST_NOTIFICATIONS -> R.string.pair_permission_notifications
            asking == Manifest.permission.CAMERA -> R.string.pair_permission_camera
            asking == LOCAL_NETWORK -> R.string.pair_permission_local_network
            else -> R.string.pair_instructions
        }
        Text(stringResource(body), style = MaterialTheme.typography.bodyLarge)
        if (needsCamera) {
            Button(onClick = ::start, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_scan)) }
        }
        TextButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.pair_cancel)) }
    }
}

/** `Manifest.permission.ACCESS_LOCAL_NETWORK`, a runtime permission from Android 17 (API 37). */
private const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"

private fun pairingPermissions(needsCamera: Boolean): List<String> = buildList {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
    if (needsCamera) add(Manifest.permission.CAMERA)
    if (Build.VERSION.SDK_INT >= 37) add(LOCAL_NETWORK)
}
