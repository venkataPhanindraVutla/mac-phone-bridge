package io.github.anmirror.feature.browse

import io.github.anmirror.protocol.v1.BrowseOutcome
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap

// The decisions behind SafFileTree, kept free of Android so they can be tested on the JVM.

/** The receiver's free-space margin (Global Constraints): an offer needs `size + 64 MiB`. */
const val FREE_MARGIN_BYTES = 64L shl 20

/** Whether [size] bytes fit in [free] with the margin to spare; an unknown [free] is taken. */
fun fitsFreeSpace(size: Long, free: Long?, margin: Long = FREE_MARGIN_BYTES): Boolean =
    free == null || (size >= 0 && size <= free - margin)

/** A picked folder on the primary shared volume, whose free space StorageManager reports. */
internal fun usesPrimaryVolume(authority: String?, treeDocumentId: String): Boolean =
    authority == EXTERNAL_STORAGE_AUTHORITY && treeDocumentId.startsWith("primary:")

internal const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"

/** A persisted URI grant, as `ContentResolver.persistedUriPermissions` lists it. */
internal data class Grant(val uri: String, val read: Boolean, val write: Boolean)

/**
 * What a `SecurityException` from a picked folder means: `REVOKED` only when its read and write
 * grant is really gone; otherwise (or when the grants can't be read, [grants] null) the folder
 * stays and the operation failed with `IO`.
 */
internal fun securityOutcome(treeUri: String, grants: List<Grant>?): BrowseOutcome {
    if (grants == null) return BrowseOutcome.BROWSE_OUTCOME_IO
    val held = grants.any { it.uri == treeUri && it.read && it.write }
    return if (held) BrowseOutcome.BROWSE_OUTCOME_IO else BrowseOutcome.BROWSE_OUTCOME_REVOKED
}

/** The two document operations placing a written file needs. */
internal interface DocOps {
    /** Renames document [id] to [name]; its ID afterwards (a provider may change it). */
    fun rename(id: String, name: String): String
    fun delete(id: String)
}

internal class Placed(val id: String, val name: String)

/**
 * Puts the finished hidden part [partId] in place as [name]. With an old file to replace
 * ([oldId]), a visible copy exists at every step:
 * 1. the part takes the free visible name [spare] (`name (n)`). If this throws, nothing moved:
 *    the old file is still there and the part, still hidden, is deleted by the abort;
 * 2. the old file is deleted. If that fails, both stay visible and the new one keeps [spare];
 * 3. the new file takes [name]. If that fails, it stays visible as [spare].
 * Only step 1 (or the single rename without an old file) can throw.
 */
internal fun placeFile(ops: DocOps, partId: String, name: String, oldId: String?, spare: String): Placed {
    if (oldId == null) return Placed(ops.rename(partId, name), name)
    val newId = ops.rename(partId, spare)
    try {
        ops.delete(oldId)
    } catch (e: Exception) {
        return Placed(newId, spare)
    }
    return try {
        Placed(ops.rename(newId, name), name)
    } catch (e: Exception) {
        Placed(newId, spare)
    }
}

/**
 * path → document ID for one tree, resolved one segment at a time by listing the parent. Every
 * cached segment is checked on use (its document must still exist under that name); on a mismatch
 * the cache is dropped and the path resolved again from the root.
 */
internal class DocPaths<D : Any>(
    private val rootId: String,
    private val children: (String) -> List<D>,
    private val query: (String) -> D?,
    private val idOf: (D) -> String,
    private val nameOf: (D) -> String,
) {
    private val ids = ConcurrentHashMap<String, String>()

    fun find(segments: List<String>): D? {
        if (segments.isEmpty()) return query(rootId)
        return walk(segments, useCache = true) ?: walk(segments, useCache = false)
    }

    fun remember(path: String, id: String) {
        ids[path] = id
    }

    /** Forgets [path] and everything under it. */
    fun invalidate(path: String) {
        ids.keys.removeIf { it == path || it.startsWith("$path/") }
    }

    /** Null when not found; with [useCache], also when a cached segment no longer matches (the cache is then dropped). */
    private fun walk(segments: List<String>, useCache: Boolean): D? {
        var parentId = rootId
        var at = ""
        for ((i, segment) in segments.withIndex()) {
            at = if (at.isEmpty()) segment else "$at/$segment"
            val last = i == segments.lastIndex
            val cached = if (useCache) ids[at] else null
            if (cached != null) {
                val doc = try {
                    query(cached)
                } catch (e: FileNotFoundException) {
                    null
                } catch (e: IllegalArgumentException) {
                    null
                }
                if (doc == null || nameOf(doc) != segment) {
                    ids.clear()
                    return null
                }
                if (last) return doc
                parentId = cached
                continue
            }
            val child = children(parentId).firstOrNull { nameOf(it) == segment } ?: return null
            ids[at] = idOf(child)
            if (last) return child
            parentId = idOf(child)
        }
        return null
    }
}
