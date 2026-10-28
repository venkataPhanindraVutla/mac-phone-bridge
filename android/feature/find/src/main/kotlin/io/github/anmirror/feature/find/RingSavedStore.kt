package io.github.anmirror.feature.find

import android.content.Context

/** What to put back after a ring: the alarm volume, and the filter if we changed it. */
data class SavedRingState(val volume: Int, val filter: Int?)

/** Survives a process death mid-ring, so the volume and Do Not Disturb are not left changed. */
interface RingSavedStore {
    fun save(state: SavedRingState)
    fun load(): SavedRingState?
    fun clear()
}

object NoRingSavedStore : RingSavedStore {
    override fun save(state: SavedRingState) = Unit
    override fun load(): SavedRingState? = null
    override fun clear() = Unit
}

class PrefsRingSavedStore(context: Context) : RingSavedStore {
    private val prefs = context.applicationContext.getSharedPreferences("find_ring", Context.MODE_PRIVATE)

    override fun save(state: SavedRingState) {
        prefs.edit().putInt(VOLUME, state.volume).apply {
            if (state.filter != null) putInt(FILTER, state.filter) else remove(FILTER)
        }.commit() // synchronous: must be on disk before the volume changes
    }

    override fun load(): SavedRingState? {
        if (!prefs.contains(VOLUME)) return null
        return SavedRingState(prefs.getInt(VOLUME, 0), if (prefs.contains(FILTER)) prefs.getInt(FILTER, 0) else null)
    }

    override fun clear() {
        prefs.edit().clear().commit()
    }

    private companion object {
        const val VOLUME = "volume"
        const val FILTER = "filter"
    }
}
