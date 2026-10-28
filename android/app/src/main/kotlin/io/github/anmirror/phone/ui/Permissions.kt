package io.github.anmirror.phone.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import io.github.anmirror.phone.R
import io.github.anmirror.phone.service.PhoneNotificationListener

/** `Manifest.permission.ACCESS_LOCAL_NETWORK`, a runtime permission from Android 17 (API 37). */
const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"

/** Pairing's permissions, in the order they are asked: notifications, camera, local network (37+). */
fun pairingPermissions(needsCamera: Boolean): List<String> = buildList {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.POST_NOTIFICATIONS)
    if (needsCamera) add(Manifest.permission.CAMERA)
    if (Build.VERSION.SDK_INT >= 37) add(LOCAL_NETWORK)
}

fun Context.isGranted(permission: String): Boolean =
    ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

/** The explanation shown while [permission]'s system dialog is up. */
fun permissionRationale(permission: String?): Int? = when (permission) {
    Manifest.permission.POST_NOTIFICATIONS -> R.string.pair_permission_notifications
    Manifest.permission.CAMERA -> R.string.pair_permission_camera
    LOCAL_NETWORK -> R.string.pair_permission_local_network
    else -> null
}

/** Asks for each missing permission in turn; a denial moves on. Then calls `onDone`. */
class PermissionChain internal constructor(
    private val permissions: List<String>,
    private val context: Context,
    private val launch: (String) -> Unit,
    private val onDone: () -> Unit,
    private val position: () -> Int,
    private val setPosition: (Int) -> Unit,
    private val setAsking: (String?) -> Unit,
) {
    fun start() {
        setPosition(0)
        next()
    }

    internal fun next() {
        var i = position()
        while (i < permissions.size && context.isGranted(permissions[i])) i++
        if (i < permissions.size) {
            setPosition(i + 1)
            setAsking(permissions[i])
            launch(permissions[i])
        } else {
            setPosition(i)
            setAsking(null)
            onDone()
        }
    }
}

/** A [PermissionChain] for [permissions], and the permission being asked for right now. */
@Composable
fun rememberPermissionChain(permissions: List<String>, onDone: () -> Unit): Pair<PermissionChain, String?> {
    val context = LocalContext.current
    val done by rememberUpdatedState(onDone)
    var position by rememberSaveable { mutableStateOf(0) }
    var asking by rememberSaveable { mutableStateOf<String?>(null) }
    var chain: PermissionChain? = null
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { chain?.next() }
    chain = remember(permissions, launcher) {
        PermissionChain(
            permissions, context, launcher::launch, { done() },
            { position }, { position = it }, { asking = it },
        )
    }
    return chain to asking
}

/**
 * Opens this app's notification-access page in Settings (API 30+), else the list of apps. Access
 * can only be granted there; it is never a runtime prompt.
 */
fun Context.openNotificationAccessSettings() {
    val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS).putExtra(
            Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
            ComponentName(this, PhoneNotificationListener::class.java).flattenToString(),
        )
    } else {
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
    }
    try {
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (e: android.content.ActivityNotFoundException) {
        // Some builds lack the detail page: fall back to the list.
        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
