package io.github.anmirror.feature.input

/**
 * Landscape keyboard: two fingers on the side rails swiping up open the trackpad, swiping down
 * close it. Fingers are tracked by pointer id with y in dp, from either rail (same top and height).
 * One swipe fires once until every finger has lifted.
 */
class SideSwipe(private val thresholdDp: Float = 40f) {
    enum class Result { NONE, UP, DOWN }

    private val fingers = HashMap<Long, FloatArray>() // id -> [startY, y]
    private var fired = false

    fun down(id: Long, y: Float) {
        if (fingers.isEmpty()) fired = false
        fingers[id] = floatArrayOf(y, y)
    }

    fun move(id: Long, y: Float): Result {
        val f = fingers[id] ?: return Result.NONE
        f[1] = y
        if (fired || fingers.size < 2) return Result.NONE
        val moves = fingers.values.map { it[1] - it[0] }
        val result = when {
            moves.all { it < -thresholdDp } -> Result.UP
            moves.all { it > thresholdDp } -> Result.DOWN
            else -> return Result.NONE
        }
        fired = true
        return result
    }

    fun up(id: Long) { fingers.remove(id) }
}
