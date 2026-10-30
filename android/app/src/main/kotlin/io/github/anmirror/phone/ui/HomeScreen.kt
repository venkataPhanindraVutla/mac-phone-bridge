package io.github.anmirror.phone.ui

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PhoneConnectionState
import io.github.anmirror.phone.MediaAccess
import io.github.anmirror.phone.R
import io.github.anmirror.feature.browse.PickedFolders
import io.github.anmirror.phone.copyNamesMac
import io.github.anmirror.phone.dndRowLines
import io.github.anmirror.phone.forgetBodyRes
import io.github.anmirror.phone.messageRes
import io.github.anmirror.phone.proximityRowLine
import io.github.anmirror.feature.proximity.AdvertiserState
import io.github.anmirror.protocol.v1.DndAvailability

/** The paired Mac, the connection state from ConnectionManager, and Forget this Mac. */
@Composable
fun HomeScreen(
    mac: PairedMac,
    state: PhoneConnectionState,
    ringing: Boolean,
    onStopRing: () -> Unit,
    onRetry: () -> Unit,
    notifyOn: Boolean,
    notifyAccess: Boolean,
    onNotifyToggle: (Boolean) -> Unit,
    mediaControlOn: Boolean,
    onMediaControlToggle: (Boolean) -> Unit,
    dndSyncOn: Boolean,
    dndAccess: Boolean,
    macDnd: DndAvailability?,
    onDndSyncToggle: (Boolean) -> Unit,
    proximityOn: Boolean,
    proximityGranted: Boolean,
    proximityAdapter: AdvertiserState,
    onProximityToggle: (Boolean) -> Unit,
    onProximityPermissionResult: () -> Unit,
    trackpadShown: Boolean,
    trackpadOpen: Boolean,
    trackpadLine: Int?,
    onOpenTrackpad: () -> Unit,
    contactsOn: Boolean,
    contactsGranted: Boolean,
    onContactsToggle: (Boolean) -> Unit,
    onContactsPermissionResult: () -> Unit,
    callsOn: Boolean,
    callsGranted: Boolean,
    onCallsToggle: (Boolean) -> Unit,
    onCallsPermissionResult: () -> Unit,
    clipboardOn: Boolean,
    onClipboardToggle: (Boolean) -> Unit,
    screenshotsOn: Boolean,
    mediaAccess: MediaAccess,
    onScreenshotsToggle: (Boolean) -> Unit,
    onMediaPermissionResult: () -> Unit,
    photosOn: Boolean,
    photosAccess: MediaAccess,
    onPhotosToggle: (Boolean) -> Unit,
    browseOn: Boolean,
    allFilesOffered: Boolean,
    allFilesAccess: Boolean,
    pickedFolders: List<PickedFolders.Folder>,
    onBrowseToggle: (Boolean) -> Unit,
    onFolderPicked: (Uri) -> Unit,
    onRemoveFolder: (PickedFolders.Folder) -> Unit,
    onForget: () -> Unit,
    onPairAgain: () -> Unit,
) {
    var confirmForget by rememberSaveable { mutableStateOf(false) }
    var confirmPairAgain by rememberSaveable { mutableStateOf(false) }
    // Scrolls when the rows do not fit; when they do, Forget still sits at the bottom (the scroll
    // keeps the screen's height as the minimum, so the weighted spacer fills the rest).
    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (ringing) {
            val label = stringResource(R.string.home_stop_ringing_label)
            Button(
                onClick = onStopRing,
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = label },
            ) { Text(stringResource(R.string.home_stop_ringing)) }
        }
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
        NotifyRow(on = notifyOn, access = notifyAccess, onToggle = onNotifyToggle)
        MediaRow(on = mediaControlOn, access = notifyAccess, onToggle = onMediaControlToggle)
        DndRow(on = dndSyncOn, access = dndAccess, mac = macDnd, onToggle = onDndSyncToggle)
        ProximityRow(
            on = proximityOn, granted = proximityGranted, adapter = proximityAdapter,
            onToggle = onProximityToggle, onPermissionResult = onProximityPermissionResult,
        )
        if (trackpadShown) TrackpadRow(open = trackpadOpen, line = trackpadLine, onOpen = onOpenTrackpad)
        ContactsRow(on = contactsOn, granted = contactsGranted, onToggle = onContactsToggle, onPermissionResult = onContactsPermissionResult)
        CallsRow(on = callsOn, granted = callsGranted, onToggle = onCallsToggle, onPermissionResult = onCallsPermissionResult)
        ClipboardRow(on = clipboardOn, onToggle = onClipboardToggle)
        ScreenshotsRow(
            on = screenshotsOn, access = mediaAccess, onToggle = onScreenshotsToggle,
            onPermissionResult = onMediaPermissionResult,
        )
        PhotosRow(on = photosOn, access = photosAccess, onToggle = onPhotosToggle, onPermissionResult = onMediaPermissionResult)
        BrowseRow(
            on = browseOn, allFilesOffered = allFilesOffered, allFilesAccess = allFilesAccess, folders = pickedFolders,
            onToggle = onBrowseToggle, onFolderPicked = onFolderPicked, onRemove = onRemoveFolder,
        )
        FindMyPhoneRow()
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
            text = { Text(stringResource(state.forgetBodyRes())) },
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

/**
 * Find my phone: ringing at full volume on silent needs no permission, but ringing through Do Not
 * Disturb's Total silence needs the special "Do Not Disturb access", which only Settings can grant.
 */
@Composable
private fun FindMyPhoneRow() {
    val context = LocalContext.current
    val nm = context.getSystemService(NotificationManager::class.java)
    var granted by remember { mutableStateOf(nm.isNotificationPolicyAccessGranted) }
    // Back from Settings: re-read.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { granted = nm.isNotificationPolicyAccessGranted }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            stringResource(R.string.home_find_title),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            stringResource(if (granted) R.string.home_find_granted else R.string.home_find_needs_access),
            style = MaterialTheme.typography.bodyMedium,
        )
        if (!granted) {
            OutlinedButton(
                onClick = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)) },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.home_find_allow)) }
        }
    }
}

/**
 * "Show notifications on your Mac": the switch is the user's choice; notification access is the
 * system's, granted in Settings. Turning the switch on without access opens that page.
 */
@Composable
private fun NotifyRow(on: Boolean, access: Boolean, onToggle: (Boolean) -> Unit) {
    val context = LocalContext.current
    val title = stringResource(R.string.home_notify_title)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            Switch(
                checked = on,
                onCheckedChange = { checked ->
                    onToggle(checked)
                    if (checked && !access) context.openNotificationAccessSettings()
                },
                modifier = Modifier.semantics { contentDescription = title },
            )
        }
        if (on && !access) {
            Text(stringResource(R.string.home_notify_needs_access), style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(
                onClick = { context.openNotificationAccessSettings() },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.home_notify_allow)) }
        }
    }
}

/**
 * "Control media from your Mac": on by default. The phone's media sessions are read through the
 * notification listener, so it needs notification access, granted in Settings; turning the switch
 * on without it opens that page.
 */
@Composable
private fun MediaRow(on: Boolean, access: Boolean, onToggle: (Boolean) -> Unit) {
    val context = LocalContext.current
    val title = stringResource(R.string.home_media_title)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            Switch(
                checked = on,
                onCheckedChange = { checked ->
                    onToggle(checked)
                    if (checked && !access) context.openNotificationAccessSettings()
                },
                modifier = Modifier.semantics { contentDescription = title },
            )
        }
        if (on && !access) {
            Text(stringResource(R.string.home_notify_needs_access), style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(
                onClick = { context.openNotificationAccessSettings() },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.home_notify_allow)) }
        }
    }
}

/**
 * "Sync Do Not Disturb with your Mac": off by default. Sending the phone's Do Not Disturb needs no
 * permission; applying the Mac's Focus needs Do Not Disturb access, which only Settings grants, so
 * turning the switch on without it opens that page. The lines say what works in each direction.
 */
@Composable
private fun DndRow(on: Boolean, access: Boolean, mac: DndAvailability?, onToggle: (Boolean) -> Unit) {
    val context = LocalContext.current
    val title = stringResource(R.string.home_dnd_title)
    val openAccess = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            Switch(
                checked = on,
                onCheckedChange = { checked ->
                    onToggle(checked)
                    if (checked && !access) openAccess()
                },
                modifier = Modifier.semantics { contentDescription = title },
            )
        }
        for (line in dndRowLines(on, access, mac)) {
            Text(stringResource(line), style = MaterialTheme.typography.bodyMedium)
        }
        if (on && !access) {
            Text(stringResource(R.string.home_dnd_needs_access), style = MaterialTheme.typography.bodyMedium)
            val allowDescription = stringResource(R.string.home_dnd_allow_description)
            OutlinedButton(
                onClick = openAccess,
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = allowDescription },
            ) {
                Text(stringResource(R.string.home_find_allow))
            }
        }
    }
}

/**
 * "Let your Mac lock when you walk away": off by default. Nearby devices (BLUETOOTH_ADVERTISE,
 * API 31+) is asked for only when the switch is turned on; if refused, the way back is the app's
 * page in Settings. With the permission, the note says when Bluetooth is off or can't advertise.
 */
@Composable
private fun ProximityRow(
    on: Boolean,
    granted: Boolean,
    adapter: AdvertiserState,
    onToggle: (Boolean) -> Unit,
    onPermissionResult: () -> Unit,
) {
    val context = LocalContext.current
    val title = stringResource(R.string.home_proximity_title)
    val (chain, _) = rememberPermissionChain(proximityPermissions(), onDone = onPermissionResult)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            Switch(
                checked = on,
                onCheckedChange = { checked ->
                    onToggle(checked)
                    if (checked) chain.start()
                },
                modifier = Modifier.semantics { contentDescription = title },
            )
        }
        proximityRowLine(on, granted, adapter)?.let { line ->
            Text(stringResource(line), style = MaterialTheme.typography.bodyMedium)
        }
        if (on && !granted) {
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.home_proximity_allow)) }
        }
    }
}

/**
 * "Use as trackpad", shown while connected to a Mac that has the trackpad: it opens the trackpad
 * once the Mac allows it, and until then the line says what to turn on there. No permission and no
 * switch on the phone.
 */
@Composable
private fun TrackpadRow(open: Boolean, line: Int?, onOpen: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = onOpen, enabled = open, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.home_trackpad))
        }
        if (line != null) Text(stringResource(line), style = MaterialTheme.typography.bodyMedium)
    }
}

/**
 * "Share contacts with your Mac": READ_CONTACTS is asked for only when the switch is turned on. If
 * it was refused, the way back is the app's page in Settings.
 */
@Composable
private fun ContactsRow(on: Boolean, granted: Boolean, onToggle: (Boolean) -> Unit, onPermissionResult: () -> Unit) {
    val context = LocalContext.current
    val title = stringResource(R.string.home_contacts_title)
    val (chain, _) = rememberPermissionChain(listOf(Manifest.permission.READ_CONTACTS), onDone = onPermissionResult)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            Switch(
                checked = on,
                onCheckedChange = { checked ->
                    onToggle(checked)
                    if (checked) chain.start()
                },
                modifier = Modifier.semantics { contentDescription = title },
            )
        }
        if (on && !granted) {
            Text(stringResource(R.string.home_contacts_needs_permission), style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.home_contacts_allow)) }
        }
    }
}

/** "Share clipboard with your Mac": no permission is involved. */
@Composable
private fun ClipboardRow(on: Boolean, onToggle: (Boolean) -> Unit) {
    val title = stringResource(R.string.home_clipboard_title)
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            title,
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f).semantics { heading() },
        )
        Switch(
            checked = on,
            onCheckedChange = onToggle,
            modifier = Modifier.semantics { contentDescription = title },
        )
    }
}

/**
 * "Send screenshots to your Mac": access to all photos is asked for only when the switch is turned
 * on. With only some photos allowed, new screenshots can't be found, and the row says so. Either
 * way back is the app's page in Settings.
 */
@Composable
private fun ScreenshotsRow(on: Boolean, access: MediaAccess, onToggle: (Boolean) -> Unit, onPermissionResult: () -> Unit) {
    val context = LocalContext.current
    val title = stringResource(R.string.home_screenshots_title)
    val done by rememberUpdatedState(onPermissionResult)
    // One request, not a chain: on API 34+ it carries the picked-photos grant with the images one.
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { done() }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            Switch(
                checked = on,
                onCheckedChange = { checked ->
                    onToggle(checked)
                    if (checked && access != MediaAccess.FULL) ask.launch(screenshotPermissions().toTypedArray())
                },
                modifier = Modifier.semantics { contentDescription = title },
            )
        }
        if (on && access != MediaAccess.FULL) {
            val note = if (access == MediaAccess.PARTIAL) R.string.home_screenshots_partial else R.string.home_screenshots_needs_permission
            Text(stringResource(note), style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.home_screenshots_allow)) }
        }
    }
}

/**
 * "Show recent photos on your Mac": photo and video access is asked for only when the switch is
 * turned on, in one system dialog. With only some photos allowed, those are shown on the Mac, and
 * the row says so; with none, it says access is needed. Either way back is the app's page in Settings.
 */
@Composable
private fun PhotosRow(on: Boolean, access: MediaAccess, onToggle: (Boolean) -> Unit, onPermissionResult: () -> Unit) {
    val context = LocalContext.current
    val title = stringResource(R.string.home_photos_title)
    val done by rememberUpdatedState(onPermissionResult)
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { done() }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            Switch(
                checked = on,
                onCheckedChange = { checked ->
                    onToggle(checked)
                    // Images alone (allowed for screenshots, say) are PARTIAL here, so videos get asked for too.
                    if (checked && access != MediaAccess.FULL) ask.launch(photosPermissions().toTypedArray())
                },
                modifier = Modifier.semantics { contentDescription = title },
            )
        }
        if (on && access != MediaAccess.FULL) {
            val note = if (access == MediaAccess.PARTIAL) R.string.home_photos_partial else R.string.home_screenshots_needs_permission
            Text(stringResource(note), style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.home_screenshots_allow)) }
        }
    }
}

/**
 * "Browse phone files from your Mac": nothing is asked for when the switch is turned on. While it
 * is on, the row offers "Allow access to all files" (this build has it and the system is API 30+,
 * until it is granted, in Settings), and always "Add folder" (the system folder picker; the grant is
 * kept), with each picked folder and its "Remove".
 */
@Composable
private fun BrowseRow(
    on: Boolean,
    allFilesOffered: Boolean,
    allFilesAccess: Boolean,
    folders: List<PickedFolders.Folder>,
    onToggle: (Boolean) -> Unit,
    onFolderPicked: (Uri) -> Unit,
    onRemove: (PickedFolders.Folder) -> Unit,
) {
    val context = LocalContext.current
    val title = stringResource(R.string.home_browse_title)
    val picked by rememberUpdatedState(onFolderPicked)
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri -> uri?.let { picked(it) } }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            Switch(
                checked = on,
                onCheckedChange = onToggle,
                modifier = Modifier.semantics { contentDescription = title },
            )
        }
        if (!on) return@Column
        if (allFilesOffered && !allFilesAccess && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            OutlinedButton(
                onClick = { context.openAllFilesAccessSettings() },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.home_browse_allow_all)) }
        }
        OutlinedButton(onClick = { pick.launch(null) }, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.home_browse_add_folder))
        }
        for (folder in folders) {
            val removeLabel = stringResource(R.string.home_browse_remove_label, folder.root.name)
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(folder.root.name, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                TextButton(
                    onClick = { onRemove(folder) },
                    modifier = Modifier.semantics { contentDescription = removeLabel },
                ) { Text(stringResource(R.string.home_browse_remove)) }
            }
        }
    }
}

/**
 * "Calls on your Mac": READ_PHONE_STATE (plus the call log and answering permissions, where this
 * build has them) is asked for only when the switch is turned on. If refused, the way back is the
 * app's page in Settings.
 */
@Composable
private fun CallsRow(on: Boolean, granted: Boolean, onToggle: (Boolean) -> Unit, onPermissionResult: () -> Unit) {
    val context = LocalContext.current
    val title = stringResource(R.string.home_calls_title)
    val (chain, _) = rememberPermissionChain(callsPermissions(), onDone = onPermissionResult)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f).semantics { heading() },
            )
            Switch(
                checked = on,
                onCheckedChange = { checked ->
                    onToggle(checked)
                    if (checked) chain.start()
                },
                modifier = Modifier.semantics { contentDescription = title },
            )
        }
        if (on && !granted) {
            Text(stringResource(R.string.home_calls_needs_permission), style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)),
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(stringResource(R.string.home_calls_allow)) }
        }
    }
}
