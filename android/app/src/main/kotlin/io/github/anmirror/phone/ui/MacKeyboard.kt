package io.github.anmirror.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.anmirror.feature.input.KeyModifiers
import io.github.anmirror.feature.input.KeyModifiers.Companion.COMMAND
import io.github.anmirror.feature.input.KeyModifiers.Companion.CONTROL
import io.github.anmirror.feature.input.KeyModifiers.Companion.FN
import io.github.anmirror.feature.input.KeyModifiers.Companion.OPTION
import io.github.anmirror.feature.input.KeyModifiers.Companion.SHIFT
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * One key cap. [code] is the macOS virtual key code; [mod] a [KeyModifiers] bit for ⇧ ⌃ ⌥ ⌘ fn;
 * [name] is what TalkBack reads. [top] is the shifted symbol printed above the main label.
 */
private class MacKey(
    val label: String,
    val code: Int,
    val width: Float = 1f,
    val top: String? = null,
    val mod: Int = 0,
    val name: String = label,
    val align: Alignment = Alignment.Center,
    val letter: Boolean = false,
)

private fun letter(c: Char, code: Int) = MacKey(c.toString(), code, letter = true)
private fun sym(label: String, top: String, code: Int) = MacKey(label, code, top = top)
private const val CAPS = 57

// The MacBook Air's built-in US (ANSI) keyboard, row by row; widths in key units.
private val FN_ROW = listOf(
    MacKey("esc", 53, 1.5f, align = Alignment.BottomStart),
    MacKey("☼", 122, top = "F1", name = "F1, brightness down"), MacKey("☀", 120, top = "F2", name = "F2, brightness up"),
    MacKey("⊞", 99, top = "F3", name = "F3, Mission Control"), MacKey("⌕", 118, top = "F4", name = "F4, Spotlight"),
    MacKey("🎙", 96, top = "F5", name = "F5"), MacKey("☾", 97, top = "F6", name = "F6"),
    MacKey("⏪", 98, top = "F7", name = "F7, previous"), MacKey("⏯", 100, top = "F8", name = "F8, play or pause"),
    MacKey("⏩", 101, top = "F9", name = "F9, next"), MacKey("🔇", 109, top = "F10", name = "F10, mute"),
    MacKey("🔉", 103, top = "F11", name = "F11, volume down"), MacKey("🔊", 111, top = "F12", name = "F12, volume up"),
)
private val ROWS = listOf(
    listOf(
        sym("`", "~", 50), sym("1", "!", 18), sym("2", "@", 19), sym("3", "#", 20), sym("4", "$", 21), sym("5", "%", 23),
        sym("6", "^", 22), sym("7", "&", 26), sym("8", "*", 28), sym("9", "(", 25), sym("0", ")", 29), sym("-", "_", 27),
        sym("=", "+", 24), MacKey("delete", 51, 1.5f, align = Alignment.BottomEnd),
    ),
    listOf(MacKey("tab", 48, 1.5f, align = Alignment.BottomStart)) +
        "QWERTYUIOP".toList().zip(listOf(12, 13, 14, 15, 17, 16, 32, 34, 31, 35)) { c, k -> letter(c, k) } +
        listOf(sym("[", "{", 33), sym("]", "}", 30), sym("\\", "|", 42)),
    listOf(MacKey("caps lock", CAPS, 1.8f, align = Alignment.BottomStart)) +
        "ASDFGHJKL".toList().zip(listOf(0, 1, 2, 3, 5, 4, 38, 40, 37)) { c, k -> letter(c, k) } +
        listOf(sym(";", ":", 41), sym("'", "\"", 39), MacKey("return", 36, 1.7f, align = Alignment.BottomEnd)),
    listOf(MacKey("shift", 56, 2.3f, mod = SHIFT, align = Alignment.BottomStart)) +
        "ZXCVBNM".toList().zip(listOf(6, 7, 8, 9, 11, 45, 46)) { c, k -> letter(c, k) } +
        listOf(sym(",", "<", 43), sym(".", ">", 47), sym("/", "?", 44), MacKey("shift", 60, 2.2f, mod = SHIFT, align = Alignment.BottomEnd)),
)
private val BOTTOM_LEFT = listOf(
    MacKey("fn", 63, top = "🌐", mod = FN, align = Alignment.BottomStart),
    MacKey("control", 59, top = "⌃", mod = CONTROL, align = Alignment.BottomStart),
    MacKey("option", 58, top = "⌥", mod = OPTION, align = Alignment.BottomStart),
    MacKey("command", 55, 1.3f, top = "⌘", mod = COMMAND, align = Alignment.BottomStart),
)
private val SPACE = MacKey("", 49, 5.2f, name = "space")
private val BOTTOM_RIGHT = listOf(
    MacKey("command", 54, 1.3f, top = "⌘", mod = COMMAND, align = Alignment.BottomEnd),
    MacKey("option", 61, top = "⌥", mod = OPTION, align = Alignment.BottomEnd),
)
private val LEFT = MacKey("◀", 123, name = "left arrow")
private val UP = MacKey("▲", 126, name = "up arrow")
private val DOWN = MacKey("▼", 125, name = "down arrow")
private val RIGHT = MacKey("▶", 124, name = "right arrow")

private val Board = Color(0xFF08080A)
private val Cap = Color(0xFF232326)
private val CapDown = Color(0xFF161618)
private val CapText = Color(0xFFE9E9EC)
private val CapSub = Color(0xFFB4B4BA)

/**
 * The Mac keyboard (`keyboard.v1`): every key sends its macOS key code with the modifiers in
 * effect ([onKey]). [feedback] runs on each press and release (sound, haptic). Holding a normal
 * key repeats it, as on the Mac.
 */
@Composable
fun MacKeyboard(
    modifiers: KeyModifiers,
    onKey: (code: Int, modifiers: Int) -> Unit,
    feedback: (down: Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Bumped on every modifier change, so the caps repaint (KeyModifiers is plain Kotlin).
    var version by remember { mutableIntStateOf(0) }
    val bump: () -> Unit = { version++ }
    val keyRow: @Composable RowScope.(MacKey) -> Unit = { k ->
        KeyCap(k, modifiers, version, onKey, feedback, bump, Modifier.weight(k.width).fillMaxHeight())
    }
    Column(
        modifier = modifier.clip(RoundedCornerShape(14.dp)).background(Board).padding(5.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(Modifier.weight(0.62f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            FN_ROW.forEach { keyRow(it) }
            // Touch ID: drawn for the likeness, sends nothing.
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) {
                Box(Modifier.size(22.dp).clip(CircleShape).border(1.5.dp, Color(0xFF2C2C30), CircleShape))
            }
        }
        ROWS.forEach { row ->
            Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) { row.forEach { keyRow(it) } }
        }
        Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            BOTTOM_LEFT.forEach { keyRow(it) }
            keyRow(SPACE)
            BOTTOM_RIGHT.forEach { keyRow(it) }
            // The arrows: half-height left and right, up over down in the middle.
            Row(Modifier.weight(3f).fillMaxHeight(), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    Spacer(Modifier.weight(1f))
                    KeyCap(LEFT, modifiers, version, onKey, feedback, bump, Modifier.weight(1f).fillMaxWidth())
                }
                Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    KeyCap(UP, modifiers, version, onKey, feedback, bump, Modifier.weight(1f).fillMaxWidth())
                    KeyCap(DOWN, modifiers, version, onKey, feedback, bump, Modifier.weight(1f).fillMaxWidth())
                }
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    Spacer(Modifier.weight(1f))
                    KeyCap(RIGHT, modifiers, version, onKey, feedback, bump, Modifier.weight(1f).fillMaxWidth())
                }
            }
        }
    }
}

@Composable
private fun KeyCap(
    key: MacKey,
    modifiers: KeyModifiers,
    @Suppress("UNUSED_PARAMETER") version: Int, // changes when a modifier does, so this cap repaints
    onKey: (Int, Int) -> Unit,
    feedback: (Boolean) -> Unit,
    changed: () -> Unit,
    modifier: Modifier,
) {
    val scope = rememberCoroutineScope()
    var pressed by remember { mutableStateOf(false) }
    val send by rememberUpdatedState(onKey)
    val feel by rememberUpdatedState(feedback)
    val accent = MaterialTheme.colorScheme.primary
    val state = if (key.mod != 0) modifiers.state(key.mod) else KeyModifiers.State.OFF
    val capsOn = key.code == CAPS && modifiers.capsLock

    fun press(): Job? {
        if (key.mod != 0) { modifiers.down(key.mod); return null }
        if (key.code == CAPS) { modifiers.toggleCapsLock(); changed(); return null }
        val bits = modifiers.press(key.letter)
        send(key.code, bits)
        changed()
        // Held: repeat after 450 ms, every 60 ms, with the modifiers of the first press.
        return scope.launch {
            delay(450)
            while (true) { send(key.code, bits); delay(60) }
        }
    }

    fun release() {
        if (key.mod != 0) { modifiers.up(key.mod); changed() }
    }

    Box(
        modifier = modifier
            .offset(y = if (pressed) 1.dp else 0.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(
                when {
                    state == KeyModifiers.State.LOCKED -> accent
                    pressed -> CapDown
                    else -> Cap
                },
            )
            .then(if (state == KeyModifiers.State.LATCHED) Modifier.border(1.5.dp, accent, RoundedCornerShape(6.dp)) else Modifier)
            .semantics {
                contentDescription = key.name
                role = Role.Button
                if (key.mod != 0) stateDescription = state.name.lowercase()
                if (key.code == CAPS) stateDescription = if (capsOn) "on" else "off"
                onClick { press()?.cancel(); release(); true }
            }
            .pointerInput(key) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false).consume()
                    pressed = true
                    feel(true)
                    val repeat = press()
                    waitForUpOrCancellation()?.consume()
                    repeat?.cancel()
                    pressed = false
                    feel(false)
                    release()
                }
            }
            .padding(horizontal = 5.dp, vertical = 3.dp),
        contentAlignment = key.align,
    ) {
        val text = if (state == KeyModifiers.State.LOCKED) Color(0xFF0B0B0B) else if (state == KeyModifiers.State.LATCHED) accent else CapText
        when {
            key.top != null && key.mod != 0 -> Column(horizontalAlignment = if (key.align == Alignment.BottomEnd) Alignment.End else Alignment.Start) {
                Text(key.top, color = text, fontSize = 12.sp, lineHeight = 13.sp)
                Text(key.label, color = text, fontSize = 9.sp, lineHeight = 10.sp, maxLines = 1)
            }
            key.top != null -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(key.top, color = CapSub, fontSize = 9.sp, lineHeight = 10.sp, maxLines = 1)
                Text(key.label, color = text, fontSize = 12.sp, lineHeight = 13.sp, maxLines = 1)
            }
            else -> Text(key.label, color = text, fontSize = if (key.label.length > 1) 10.sp else 13.sp, lineHeight = 12.sp, maxLines = 2, textAlign = TextAlign.Center)
        }
        if (capsOn) Box(Modifier.align(Alignment.TopStart).size(5.dp).clip(CircleShape).background(Color(0xFF4CFF6A)))
    }
}

/** For previews and the trackpad screen: a [KeyModifiers] on the system clock. */
@Composable
fun rememberKeyModifiers(): KeyModifiers = remember { KeyModifiers(clock = { System.currentTimeMillis() }) }

