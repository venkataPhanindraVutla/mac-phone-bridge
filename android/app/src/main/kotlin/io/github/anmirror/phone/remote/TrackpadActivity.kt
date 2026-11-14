package io.github.anmirror.phone.remote

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import io.github.anmirror.feature.input.InputEvent
import io.github.anmirror.feature.input.InputSender
import io.github.anmirror.feature.input.KeyModifiers
import io.github.anmirror.feature.input.TouchFrame
import io.github.anmirror.feature.input.TrackpadGestures
import io.github.anmirror.feature.input.TrackpadMath
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.AppTheme
import io.github.anmirror.phone.TAG
import io.github.anmirror.phone.inputOpen
import io.github.anmirror.phone.keyboardShared
import io.github.anmirror.phone.ui.KeyboardHooks
import io.github.anmirror.phone.trackpadLine
import io.github.anmirror.phone.ui.TrackpadScreen
import io.github.anmirror.phone.ui.TrackpadTab
import io.github.anmirror.protocol.v1.RemoteKey
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/**
 * The phone as the Mac's trackpad and presentation remote (F-16), opened from Home while the Mac
 * allows it. The screen stays on while it is shown. The [InputSender] lives while the activity is
 * started: a pause lets go of a held button and the laser, a stop also closes the sender (an up
 * for whatever is still held, the laser off). It finishes when the Mac stops allowing it, or the
 * connection ends; Home then says why.
 */
class TrackpadActivity : ComponentActivity() {
    private lateinit var graph: AppGraph
    private val gestures = TrackpadGestures()
    private var sender: InputSender? = null
    private var sounds: KeySounds? = null
    private val handler = Handler(Looper.getMainLooper())

    /** A still finger's long press comes due: nothing else moves then, so a timer asks. */
    private val longPress = Runnable {
        val events = gestures.tick(SystemClock.uptimeMillis())
        dispatch(events)
        if (events.isNotEmpty()) window.decorView.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    }
    private var tab by mutableStateOf(TrackpadTab.TRACKPAD)
    private var laserOn = false
    private var wasOpen = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        graph = AppGraph.get(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        savedInstanceState?.getString(KEY_TAB)?.let { saved -> TrackpadTab.entries.firstOrNull { it.name == saved }?.let { tab = it } }
        setContent {
            AppTheme {
                val state by graph.manager.state.collectAsStateWithLifecycle()
                val mac by graph.macInputAvailability.collectAsStateWithLifecycle()
                val volumeKeysOn by graph.volumeKeysOn.collectAsStateWithLifecycle()
                val keySoundsOn by graph.keySoundsOn.collectAsStateWithLifecycle()
                val keyHapticsOn by graph.keyHapticsOn.collectAsStateWithLifecycle()
                val keyboard = if (keyboardShared(state)) {
                    KeyboardHooks(
                        onKey = { code, bits -> sender?.keyCode(code, bits) },
                        playSound = { down -> if (keySoundsOn) sounds?.play(down) },
                        soundOn = keySoundsOn,
                        onSound = graph::setKeySoundsOn,
                        hapticsOn = keyHapticsOn,
                        onHaptics = graph::setKeyHapticsOn,
                    )
                } else {
                    null
                }
                Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    TrackpadScreen(
                        open = inputOpen(state, mac),
                        line = trackpadLine(state, mac),
                        tab = tab,
                        onTab = { tab = it },
                        onFrame = ::onFrame,
                        onCancel = ::cancelGesture,
                        onPrevious = { sender?.key(RemoteKey.REMOTE_KEY_PREV_SLIDE) },
                        onNext = { sender?.key(RemoteKey.REMOTE_KEY_NEXT_SLIDE) },
                        onLaser = ::laser,
                        onLaserMove = { dx, dy, dt -> TrackpadMath.move(dx, dy, dt).let { (x, y) -> sender?.move(x, y) } },
                        volumeKeysOn = volumeKeysOn,
                        onVolumeKeysToggle = graph::setVolumeKeysOn,
                        keyboard = keyboard,
                    )
                }
            }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                combine(graph.manager.state, graph.macInputAvailability, ::inputOpen)
                    .distinctUntilChanged()
                    .collect { open ->
                        if (wasOpen && !open) finish()
                        wasOpen = open
                    }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        sender = InputSender(
            scope = graph.scope,
            send = graph::sendInput,
            clock = SystemClock::uptimeMillis,
            log = { Log.w(TAG, it) },
        )
        sounds = runCatching { KeySounds() }.getOrNull() // no audio track: typing still works, silently
    }

    override fun onPause() {
        letGo()
        super.onPause()
    }

    override fun onStop() {
        letGo()
        sender?.close()
        sender = null
        sounds?.release()
        sounds = null
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(KEY_TAB, tab.name)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val key = slideKey(keyCode) ?: return super.onKeyDown(keyCode, event)
        if (event.repeatCount == 0) sender?.key(key) // holding the key moves one slide
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean =
        slideKey(keyCode) != null || super.onKeyUp(keyCode, event)

    private fun slideKey(keyCode: Int): RemoteKey? =
        volumeKeySlide(keyCode, remoteShown = tab == TrackpadTab.REMOTE && graph.inputOpen(), switchOn = graph.volumeKeysOn.value)

    /** A frame from the surface; true when it clicked. */
    private fun onFrame(frame: TouchFrame): Boolean {
        val events = gestures.onFrame(frame)
        dispatch(events)
        handler.removeCallbacks(longPress)
        // Frames carry SystemClock.uptimeMillis times, so the due time posts as is.
        gestures.longPressDueAt?.let { handler.postAtTime(longPress, it) }
        return events.any { it is InputEvent.Click || it is InputEvent.Swipe }
    }

    private fun cancelGesture() {
        handler.removeCallbacks(longPress)
        dispatch(gestures.cancel())
    }

    private fun laser(on: Boolean) {
        if (on == laserOn) return
        laserOn = on
        sender?.laser(on)
    }

    /** The gesture and the laser end here: an up for a held button and the laser off. */
    private fun letGo() {
        cancelGesture()
        laser(false)
    }

    private fun dispatch(events: List<InputEvent>) {
        val s = sender ?: return
        for (e in events) when (e) {
            is InputEvent.Move -> s.move(e.dx, e.dy)
            is InputEvent.Scroll -> s.scroll(e.dx, e.dy)
            is InputEvent.Button -> s.button(e.button, e.down)
            is InputEvent.Click -> s.click(e.button, e.count)
            // The Mac's own three-finger swipes: ⌃← ⌃→ switch Spaces, ⌃↑ Mission Control, ⌃↓ App Exposé.
            is InputEvent.Swipe -> s.keyCode(
                when (e.direction) {
                    InputEvent.Swipe.Direction.LEFT -> 124 // fingers left: the Space to the right
                    InputEvent.Swipe.Direction.RIGHT -> 123
                    InputEvent.Swipe.Direction.UP -> 126
                    InputEvent.Swipe.Direction.DOWN -> 125
                },
                KeyModifiers.CONTROL,
            )
        }
    }

    private companion object {
        const val KEY_TAB = "tab"
    }
}

/**
 * Volume keys change slides only while the Remote tab is shown and its switch is on: up is the
 * next slide, down the previous. Otherwise null, and the key does what it always does.
 */
fun volumeKeySlide(keyCode: Int, remoteShown: Boolean, switchOn: Boolean): RemoteKey? = when {
    !remoteShown || !switchOn -> null
    keyCode == KeyEvent.KEYCODE_VOLUME_UP -> RemoteKey.REMOTE_KEY_NEXT_SLIDE
    keyCode == KeyEvent.KEYCODE_VOLUME_DOWN -> RemoteKey.REMOTE_KEY_PREV_SLIDE
    else -> null
}
