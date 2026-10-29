package io.github.anmirror.phone.ui

import android.Manifest
import android.annotation.SuppressLint
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
import io.github.anmirror.phone.BuildConfig
import io.github.anmirror.phone.MediaAccess
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

/**
 * "Calls on your Mac" permissions, in the order they are asked: the call state (required), then the
 * call log (confirms missed calls) and answering (Answer / Decline / Hang up), when this build has them.
 */
fun callsPermissions(): List<String> = buildList {
    add(Manifest.permission.READ_PHONE_STATE)
    if (BuildConfig.FEATURE_CALL_LOG) add(Manifest.permission.READ_CALL_LOG)
    if (BuildConfig.FEATURE_ANSWER_CALLS) add(Manifest.permission.ANSWER_PHONE_CALLS)
}

/**
 * "Send screenshots to your Mac": new screenshots can only be found with access to all photos,
 * READ_MEDIA_IMAGES (API 33+), or READ_EXTERNAL_STORAGE (up to 32). On API 34+ the system dialog
 * also offers "Select photos"; asking for READ_MEDIA_VISUAL_USER_SELECTED in the same request makes
 * that choice a lasting partial grant instead of one for this session only.
 */
// The newer permission names are plain strings, used only where `sdk` says the system has them;
// lint cannot follow a parameter check.
@SuppressLint("InlinedApi")
fun screenshotPermissions(sdk: Int = Build.VERSION.SDK_INT): List<String> = when {
    sdk >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
        listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
    sdk >= Build.VERSION_CODES.TIRAMISU -> listOf(Manifest.permission.READ_MEDIA_IMAGES)
    else -> listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
}

/**
 * "Show recent photos on your Mac": photos and videos, READ_MEDIA_IMAGES + READ_MEDIA_VIDEO
 * (API 33+, asked in one request so the system shows one dialog), or READ_EXTERNAL_STORAGE (up to
 * 32). On API 34+ READ_MEDIA_VISUAL_USER_SELECTED joins the request, as for screenshots: "Select
 * photos" then lasts, and the picked items are listed.
 */
// The newer permission names are plain strings, used only where `sdk` says the system has them;
// lint cannot follow a parameter check.
@SuppressLint("InlinedApi")
fun photosPermissions(sdk: Int = Build.VERSION.SDK_INT): List<String> = when {
    sdk >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> listOf(
        Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
        Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
    )
    sdk >= Build.VERSION_CODES.TIRAMISU -> listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
    else -> listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
}

/** What screenshots can read on API [sdk]: all images (FULL), the picked ones (API 34+), or none. */
// The newer permission names are plain strings, used only where `sdk` says the system has them;
// lint cannot follow a parameter check.
@SuppressLint("InlinedApi")
fun screenshotAccess(sdk: Int, granted: (String) -> Boolean): MediaAccess = when {
    sdk >= Build.VERSION_CODES.TIRAMISU && granted(Manifest.permission.READ_MEDIA_IMAGES) -> MediaAccess.FULL
    sdk < Build.VERSION_CODES.TIRAMISU && granted(Manifest.permission.READ_EXTERNAL_STORAGE) -> MediaAccess.FULL
    sdk >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) ->
        MediaAccess.PARTIAL
    else -> MediaAccess.NONE
}

/**
 * What photos can read on API [sdk]: FULL needs both images and videos (API 33+); one of them,
 * or only the picked items (API 34+), is PARTIAL, since part of the library is listed.
 */
// The newer permission names are plain strings, used only where `sdk` says the system has them;
// lint cannot follow a parameter check.
@SuppressLint("InlinedApi")
fun photosAccess(sdk: Int, granted: (String) -> Boolean): MediaAccess {
    if (sdk < Build.VERSION_CODES.TIRAMISU) {
        return if (granted(Manifest.permission.READ_EXTERNAL_STORAGE)) MediaAccess.FULL else MediaAccess.NONE
    }
    val images = granted(Manifest.permission.READ_MEDIA_IMAGES)
    val videos = granted(Manifest.permission.READ_MEDIA_VIDEO)
    return when {
        images && videos -> MediaAccess.FULL
        images || videos -> MediaAccess.PARTIAL
        sdk >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) ->
            MediaAccess.PARTIAL
        else -> MediaAccess.NONE
    }
}

/** How much of the phone's images screenshots may read right now. */
fun Context.mediaAccess(): MediaAccess = screenshotAccess(Build.VERSION.SDK_INT, ::isGranted)

/** How much of the phone's photos and videos the photos feature may read right now. */
fun Context.photosAccess(): MediaAccess = photosAccess(Build.VERSION.SDK_INT, ::isGranted)

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
