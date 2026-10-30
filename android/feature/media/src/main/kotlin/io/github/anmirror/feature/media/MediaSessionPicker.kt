package io.github.anmirror.feature.media

/**
 * One active media session, as the picker sees it. [order] is its place in the system's list of
 * active sessions: 0 is the most recently active. [lastPlayingAtMs] is when its state last became
 * `STATE_PLAYING`.
 */
data class SessionInfo(val key: String, val playing: Boolean, val lastPlayingAtMs: Long, val order: Int)

/** Which session the phone reports (SPEC 20). */
object MediaSessionPicker {
    /**
     * The playing session that started playing last (on a tie, the more recently active one),
     * else the most recently active session; null when there is none.
     */
    fun pick(sessions: List<SessionInfo>): SessionInfo? {
        val playing = sessions.filter { it.playing }
        if (playing.isNotEmpty()) {
            return playing.sortedWith(compareByDescending<SessionInfo> { it.lastPlayingAtMs }.thenBy { it.order }).first()
        }
        return sessions.minByOrNull { it.order }
    }
}
