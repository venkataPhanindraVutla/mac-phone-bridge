package io.github.anmirror.feature.browse

/** SPEC 19 browse paths: relative to a root, `/`-separated, `""` for the root itself. */
object BrowsePaths {
    /** The SPEC 19 cap, in UTF-8 bytes. */
    const val MAX_PATH_BYTES = 4_096

    /**
     * The path's segments (empty for the root), or null for `BAD_PATH`: a leading `/`, a segment
     * that is empty, `.` or `..`, a NUL anywhere, or more than 4,096 bytes of UTF-8.
     */
    fun segments(path: String): List<String>? {
        if (path.isEmpty()) return emptyList()
        if (path.startsWith('/') || '\u0000' in path) return null
        if (path.toByteArray(Charsets.UTF_8).size > MAX_PATH_BYTES) return null
        val parts = path.split('/')
        if (parts.any { it.isEmpty() || it == "." || it == ".." }) return null
        return parts
    }
}
