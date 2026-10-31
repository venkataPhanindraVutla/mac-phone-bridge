package io.github.anmirror.phone.mirror

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.os.Bundle
import android.view.Choreographer
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.protocol.v1.TestPatternMode
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The Mac's "Measure Delay…" test screens (Full mode): full screen, immersive, screen kept on,
 * black. `--ei mode 1` (DELAY) turns white while any finger is down; `--ei mode 2` (FPS) moves a
 * white bar a tenth of the height tall by 1/60 of the height on every frame. It finishes when the
 * session's test pattern turns OFF (or the session ends), and after [MAX_MS] in any case.
 */
class DelayTestActivity : ComponentActivity() {
    private lateinit var view: TestView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        view = TestView(this, fps = intent.getIntExtra(EXTRA_MODE, MODE_DELAY) == MODE_FPS)
        setContentView(view)
        val pattern = AppGraph.get(this).mirrorTestPattern
        lifecycleScope.launch {
            pattern.collect { if (it == TestPatternMode.TEST_PATTERN_MODE_OFF) finish() }
        }
        lifecycleScope.launch {
            delay(MAX_MS)
            finish()
        }
    }

    override fun onResume() {
        super.onResume()
        view.start()
    }

    override fun onPause() {
        view.stop()
        super.onPause()
    }

    /** Black; white while touched (DELAY), or a moving bar (FPS). */
    private class TestView(context: Context, private val fps: Boolean) : View(context), Choreographer.FrameCallback {
        private val paint = android.graphics.Paint().apply { color = Color.WHITE }
        private var touched = false
        private var barTop = 0f
        private var running = false

        fun start() {
            if (!fps || running) return
            running = true
            Choreographer.getInstance().postFrameCallback(this)
        }

        fun stop() {
            running = false
            Choreographer.getInstance().removeFrameCallback(this)
        }

        override fun doFrame(frameTimeNanos: Long) {
            if (!running) return
            barTop += height / 60f
            if (barTop >= height) barTop = 0f
            invalidate()
            Choreographer.getInstance().postFrameCallback(this)
        }

        override fun onDraw(canvas: Canvas) {
            canvas.drawColor(if (!fps && touched) Color.WHITE else Color.BLACK)
            if (fps) canvas.drawRect(0f, barTop, width.toFloat(), barTop + height / 10f, paint)
        }

        // A test surface with nothing to click; touches only change the colour.
        @SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(event: MotionEvent): Boolean {
            if (fps) return false
            val down = when (event.actionMasked) {
                MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_MOVE -> true
                MotionEvent.ACTION_POINTER_UP -> event.pointerCount > 1
                else -> false // UP, CANCEL
            }
            if (down != touched) {
                touched = down
                invalidate()
            }
            return true
        }
    }

    companion object {
        const val EXTRA_MODE = "mode"
        const val MODE_DELAY = 1
        const val MODE_FPS = 2
        const val MAX_MS = 120_000L
    }
}
