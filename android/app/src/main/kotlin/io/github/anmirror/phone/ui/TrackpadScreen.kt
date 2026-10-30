package io.github.anmirror.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.anmirror.feature.input.Touch
import io.github.anmirror.feature.input.TouchFrame
import io.github.anmirror.phone.R

enum class TrackpadTab { TRACKPAD, REMOTE }

/**
 * The trackpad and presentation remote (F-16). While the Mac doesn't allow it ([open] false) it
 * shows only why ([line]). The Trackpad tab is one surface that reports every finger
 * ([onFrame], true when the frame clicked, for the haptic) and [onCancel] when the gesture is
 * taken away; the Remote tab has Previous and Next, the laser pad and the volume keys switch.
 */
@Composable
fun TrackpadScreen(
    open: Boolean,
    line: Int?,
    tab: TrackpadTab,
    onTab: (TrackpadTab) -> Unit,
    onFrame: (TouchFrame) -> Boolean,
    onCancel: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onLaser: (Boolean) -> Unit,
    onLaserMove: (dxDp: Float, dyDp: Float, dtMs: Long) -> Unit,
    volumeKeysOn: Boolean,
    onVolumeKeysToggle: (Boolean) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
        Text(
            stringResource(R.string.trackpad_title),
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 16.dp).semantics { heading() },
        )
        if (!open) {
            if (line != null) {
                Text(
                    stringResource(line),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.padding(horizontal = 24.dp).semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
            return@Column
        }
        PrimaryTabRow(selectedTabIndex = tab.ordinal) {
            Tab(
                selected = tab == TrackpadTab.TRACKPAD,
                onClick = { onTab(TrackpadTab.TRACKPAD) },
                text = { Text(stringResource(R.string.trackpad_tab_trackpad)) },
            )
            Tab(
                selected = tab == TrackpadTab.REMOTE,
                onClick = { onTab(TrackpadTab.REMOTE) },
                text = { Text(stringResource(R.string.trackpad_tab_remote)) },
            )
        }
        val content = Modifier.weight(1f).fillMaxWidth().padding(16.dp)
        when (tab) {
            TrackpadTab.TRACKPAD -> TrackpadSurface(onFrame = onFrame, onCancel = onCancel, modifier = content)
            TrackpadTab.REMOTE -> RemotePanel(
                onPrevious = onPrevious,
                onNext = onNext,
                onLaser = onLaser,
                onLaserMove = onLaserMove,
                volumeKeysOn = volumeKeysOn,
                onVolumeKeysToggle = onVolumeKeysToggle,
                modifier = content,
            )
        }
    }
}

/**
 * Compose's ACTION_CANCEL: every pointer up and already consumed (a real lift is not), so it is
 * not taken for a lift, which could click.
 */
private fun PointerEvent.isCancel(): Boolean =
    type == PointerEventType.Release && changes.isNotEmpty() && changes.all { !it.pressed && it.isConsumed }

@Composable
private fun TrackpadSurface(onFrame: (TouchFrame) -> Boolean, onCancel: () -> Unit, modifier: Modifier) {
    val haptics = LocalHapticFeedback.current
    val label = stringResource(R.string.trackpad_surface_label)
    val frame by rememberUpdatedState(onFrame)
    val cancel by rememberUpdatedState(onCancel)
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(24.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .semantics { contentDescription = label }
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            if (event.isCancel()) {
                                cancel()
                                continue
                            }
                            val timeMs = event.changes.maxOfOrNull { it.uptimeMillis } ?: continue
                            val touches = event.changes.filter { it.pressed }.map {
                                Touch(it.id.value, it.position.x.toDp().value, it.position.y.toDp().value)
                            }
                            event.changes.forEach { it.consume() }
                            if (frame(TouchFrame(timeMs, touches))) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        }
                    } finally {
                        // The surface left (another tab, the screen going away) with fingers on it.
                        cancel()
                    }
                }
            },
    )
}

@Composable
private fun RemotePanel(
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onLaser: (Boolean) -> Unit,
    onLaserMove: (dxDp: Float, dyDp: Float, dtMs: Long) -> Unit,
    volumeKeysOn: Boolean,
    onVolumeKeysToggle: (Boolean) -> Unit,
    modifier: Modifier,
) {
    val volumeKeys = stringResource(R.string.trackpad_volume_keys)
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Button(onClick = onPrevious, modifier = Modifier.weight(1f).height(96.dp)) {
                Text(stringResource(R.string.trackpad_previous), style = MaterialTheme.typography.titleLarge)
            }
            Button(onClick = onNext, modifier = Modifier.weight(1f).height(96.dp)) {
                Text(stringResource(R.string.trackpad_next), style = MaterialTheme.typography.titleLarge)
            }
        }
        LaserPad(onLaser = onLaser, onLaserMove = onLaserMove, modifier = Modifier.weight(1f).fillMaxWidth())
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(volumeKeys, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            Switch(
                checked = volumeKeysOn,
                onCheckedChange = onVolumeKeysToggle,
                modifier = Modifier.semantics { contentDescription = volumeKeys },
            )
        }
    }
}

/** Press for the laser dot, move to move it, lift to hide it; one finger counts, without the tap rules. */
@Composable
private fun LaserPad(onLaser: (Boolean) -> Unit, onLaserMove: (dxDp: Float, dyDp: Float, dtMs: Long) -> Unit, modifier: Modifier) {
    val laser by rememberUpdatedState(onLaser)
    val move by rememberUpdatedState(onLaserMove)
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(24.dp))
            .background(MaterialTheme.colorScheme.secondaryContainer)
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    var on = false
                    var finger: PointerId? = null
                    var last = Offset.Zero
                    var lastMs = 0L
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.filter { it.pressed }
                            event.changes.forEach { it.consume() }
                            val c = pressed.firstOrNull { it.id == finger } ?: pressed.firstOrNull()
                            if (c == null) {
                                if (on) laser(false)
                                on = false
                                finger = null
                                continue
                            }
                            if (!on) {
                                on = true
                                laser(true)
                            } else if (c.id == finger) {
                                val d = c.position - last
                                if (d != Offset.Zero) move(d.x.toDp().value, d.y.toDp().value, c.uptimeMillis - lastMs)
                            }
                            finger = c.id
                            last = c.position
                            lastMs = c.uptimeMillis
                        }
                    } finally {
                        if (on) laser(false)
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            stringResource(R.string.trackpad_laser),
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
        )
    }
}
