package io.github.anmirror.phone.ui

import android.content.res.Configuration
import android.view.HapticFeedbackConstants
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.material3.TextButton
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.onClick
import io.github.anmirror.feature.input.SideSwipe
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
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import io.github.anmirror.feature.input.PointerSnapshot
import io.github.anmirror.feature.input.Touch
import io.github.anmirror.feature.input.TouchFrame
import io.github.anmirror.feature.input.isPointerCancel
import io.github.anmirror.phone.R

enum class TrackpadTab { TRACKPAD, REMOTE }

/** The Mac keyboard's hooks; null when the Mac doesn't have `keyboard.v1`. */
class KeyboardHooks(
    val onKey: (code: Int, modifiers: Int) -> Unit,
    val playSound: (down: Boolean) -> Unit,
    val soundOn: Boolean,
    val onSound: (Boolean) -> Unit,
    val hapticsOn: Boolean,
    val onHaptics: (Boolean) -> Unit,
)

private enum class Halves { BOTH, TRACKPAD, KEYBOARD }

/** The side rails' width in landscape, where two fingers swipe the trackpad up and down. */
private val RAIL = 36.dp

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
    keyboard: KeyboardHooks? = null,
) {
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    Column(modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
        // Landscape keeps its height for the keyboard.
        if (!landscape || !open) {
            Text(
                stringResource(R.string.trackpad_title),
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 16.dp).semantics { heading() },
            )
        }
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
        val content = Modifier.weight(1f).fillMaxWidth().padding(if (keyboard != null) 8.dp else 16.dp)
        when (tab) {
            TrackpadTab.TRACKPAD -> when {
                keyboard == null -> TrackpadSurface(onFrame = onFrame, onCancel = onCancel, modifier = content)
                landscape -> LandscapeKeyboard(keyboard, onFrame, onCancel, content)
                else -> PortraitKeyboard(keyboard, onFrame, onCancel, content)
            }
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

/** Trackpad on top, Mac keyboard below; either half can be hidden so the other fills the screen. */
@Composable
private fun PortraitKeyboard(k: KeyboardHooks, onFrame: (TouchFrame) -> Boolean, onCancel: () -> Unit, modifier: Modifier) {
    var halves by rememberSaveable { mutableStateOf(Halves.BOTH) }
    val mods = rememberKeyModifiers()
    val feel = rememberKeyFeedback(k)
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (halves != Halves.KEYBOARD) TrackpadSurface(onFrame = onFrame, onCancel = onCancel, modifier = Modifier.weight(1f).fillMaxWidth())
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            when (halves) {
                Halves.BOTH -> {
                    TextButton(onClick = { halves = Halves.KEYBOARD }) { Text(stringResource(R.string.keyboard_hide_trackpad)) }
                    TextButton(onClick = { halves = Halves.TRACKPAD }) { Text(stringResource(R.string.keyboard_hide_keyboard)) }
                }
                Halves.KEYBOARD -> TextButton(onClick = { halves = Halves.BOTH }) { Text(stringResource(R.string.keyboard_show_trackpad)) }
                Halves.TRACKPAD -> TextButton(onClick = { halves = Halves.BOTH }) { Text(stringResource(R.string.keyboard_show_keyboard)) }
            }
            Spacer(Modifier.weight(1f))
            FeedbackToggles(k)
        }
        if (halves != Halves.TRACKPAD) MacKeyboard(mods, k.onKey, feel, Modifier.weight(1f).fillMaxWidth())
    }
}

/**
 * The keyboard fills the screen at one size. Two fingers swiping up on the side rails slide the
 * trackpad up over it; swiping down, or Keyboard, slides it away.
 */
@Composable
private fun LandscapeKeyboard(k: KeyboardHooks, onFrame: (TouchFrame) -> Boolean, onCancel: () -> Unit, modifier: Modifier) {
    var padOpen by rememberSaveable { mutableStateOf(false) }
    val swipe = remember { SideSwipe() }
    val mods = rememberKeyModifiers()
    val feel = rememberKeyFeedback(k)
    Box(modifier = modifier) {
        MacKeyboard(mods, k.onKey, feel, Modifier.fillMaxSize().padding(horizontal = RAIL))
        AnimatedVisibility(
            visible = padOpen,
            modifier = Modifier.fillMaxSize().padding(horizontal = RAIL),
            enter = slideInVertically { it },
            exit = slideOutVertically { it },
        ) {
            Column(Modifier.fillMaxSize().clip(RoundedCornerShape(18.dp)).background(MaterialTheme.colorScheme.surface)) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { padOpen = false }) { Text(stringResource(R.string.keyboard_show_keyboard)) }
                    Spacer(Modifier.weight(1f))
                    FeedbackToggles(k)
                }
                TrackpadSurface(onFrame = onFrame, onCancel = onCancel, modifier = Modifier.weight(1f).fillMaxWidth())
            }
        }
        SideRail(swipe, Alignment.CenterStart, padOpen) { padOpen = it }
        SideRail(swipe, Alignment.CenterEnd, padOpen) { padOpen = it }
    }
}

@Composable
private fun BoxScope.SideRail(swipe: SideSwipe, align: Alignment, padOpen: Boolean, onOpen: (Boolean) -> Unit) {
    val set by rememberUpdatedState(onOpen)
    val label = stringResource(if (padOpen) R.string.keyboard_show_keyboard else R.string.keyboard_rail_hint)
    Box(
        modifier = Modifier
            .align(align)
            .width(RAIL)
            .fillMaxHeight()
            .semantics {
                contentDescription = label
                onClick { set(!padOpen); true }
            }
            .pointerInput(swipe) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent()
                        for (c in event.changes) {
                            val id = c.id.value
                            when {
                                !c.pressed -> swipe.up(id)
                                !c.previousPressed -> swipe.down(id, c.position.y.toDp().value)
                                else -> when (swipe.move(id, c.position.y.toDp().value)) {
                                    SideSwipe.Result.UP -> set(true)
                                    SideSwipe.Result.DOWN -> set(false)
                                    SideSwipe.Result.NONE -> Unit
                                }
                            }
                            c.consume()
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(if (padOpen) "⇣" else "⇡", color = MaterialTheme.colorScheme.outline, style = MaterialTheme.typography.titleMedium)
    }
}

/** Key sounds and vibration switches. */
@Composable
private fun FeedbackToggles(k: KeyboardHooks) {
    val sounds = stringResource(R.string.keyboard_sounds)
    val haptics = stringResource(R.string.keyboard_haptics)
    TextButton(onClick = { k.onSound(!k.soundOn) }, modifier = Modifier.semantics { contentDescription = sounds; stateDescription = if (k.soundOn) "on" else "off" }) {
        Text(if (k.soundOn) "🔊" else "🔇")
    }
    TextButton(onClick = { k.onHaptics(!k.hapticsOn) }, modifier = Modifier.semantics { contentDescription = haptics; stateDescription = if (k.hapticsOn) "on" else "off" }) {
        Text(if (k.hapticsOn) "📳" else "📴")
    }
}

/** Press and release feedback: the key vibration (when on) and the key sound. */
@Composable
private fun rememberKeyFeedback(k: KeyboardHooks): (Boolean) -> Unit {
    val view = LocalView.current
    val hooks by rememberUpdatedState(k)
    return remember(view) {
        { down: Boolean ->
            if (hooks.hapticsOn) view.performHapticFeedback(if (down) HapticFeedbackConstants.KEYBOARD_TAP else HapticFeedbackConstants.KEYBOARD_RELEASE)
            hooks.playSound(down)
        }
    }
}

/** Compose's ACTION_CANCEL ([isPointerCancel]), so it is not taken for a lift, which could click. */
private fun PointerEvent.isCancel(): Boolean =
    isPointerCancel(type == PointerEventType.Release, changes.map { PointerSnapshot(it.pressed, it.previousPressed, it.isConsumed) })

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
