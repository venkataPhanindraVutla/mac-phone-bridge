package io.github.anmirror.feature.input

/**
 * The Mac keyboard's modifier keys (⇧ ⌃ ⌥ ⌘ fn) and Caps Lock, as bits for `input.keycode`.
 *
 * A modifier tapped on its own applies to the next key only; tapped twice within [doubleTapMs]
 * it locks until tapped again. Held with one finger while another finger presses keys, it applies
 * to those keys and is not left latched when lifted. Caps Lock stays here: it adds shift to letters.
 */
class KeyModifiers(private val clock: () -> Long, private val doubleTapMs: Long = 350) {
    enum class State { OFF, LATCHED, LOCKED }

    private val latched = HashSet<Int>()
    private val locked = HashSet<Int>()
    private val held = HashMap<Int, Int>() // bit -> fingers holding it (two shift keys)
    private var usedWhileHeld = false
    private val lastTap = HashMap<Int, Long>()

    var capsLock = false
        private set

    fun state(bit: Int): State = when (bit) {
        in locked -> State.LOCKED
        in latched -> State.LATCHED
        else -> State.OFF
    }

    /** Shift is in effect for the next key (for the key caps' labels). */
    val shiftActive: Boolean get() = SHIFT in held || SHIFT in latched || SHIFT in locked

    fun down(bit: Int) {
        if (held.isEmpty()) usedWhileHeld = false
        held[bit] = (held[bit] ?: 0) + 1
    }

    fun up(bit: Int) {
        val n = (held[bit] ?: return) - 1
        if (n > 0) { held[bit] = n; return }
        held.remove(bit)
        if (!usedWhileHeld) tap(bit)
    }

    fun toggleCapsLock() { capsLock = !capsLock }

    /** The bits for a normal key pressed now; one-shot modifiers end with it. */
    fun press(isLetter: Boolean): Int {
        var bits = 0
        for (b in held.keys) bits = bits or b
        for (b in latched) bits = bits or b
        for (b in locked) bits = bits or b
        if (isLetter && capsLock) bits = bits or SHIFT
        if (held.isNotEmpty()) usedWhileHeld = true
        latched.clear()
        return bits
    }

    private fun tap(bit: Int) {
        val now = clock()
        val quick = lastTap[bit]?.let { now - it < doubleTapMs } == true
        lastTap[bit] = now
        when {
            bit in locked -> locked -= bit
            bit in latched && quick -> { latched -= bit; locked += bit }
            bit in latched -> latched -= bit
            else -> latched += bit
        }
    }

    companion object {
        const val SHIFT = 1
        const val CONTROL = 2
        const val OPTION = 4
        const val COMMAND = 8
        const val FN = 16
    }
}
