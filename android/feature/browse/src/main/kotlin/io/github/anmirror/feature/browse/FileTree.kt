package io.github.anmirror.feature.browse

import io.github.anmirror.protocol.v1.BrowseOutcome
import io.github.anmirror.protocol.v1.RootKind
import io.github.anmirror.transfer.IncomingFile
import io.github.anmirror.transfer.OutgoingFile

/** A browse root as the Mac sees it (`BrowseRoot`). */
data class RootInfo(val id: String, val name: String, val kind: RootKind, val writable: Boolean)

/** One file or folder (`BrowseEntry`). Folders have size 0 and an empty [mime]. */
data class EntryInfo(val name: String, val isDir: Boolean, val size: Long, val modifiedMs: Long, val mime: String)

sealed interface TreeResult<out T> {
    data class Ok<T>(val value: T) : TreeResult<T>
    data class Err(val outcome: BrowseOutcome) : TreeResult<Nothing>
}

/**
 * One browse root's files (SPEC 19). Every [path] is relative to the root, `/`-separated, and
 * checked with [BrowsePaths.segments] (`BAD_PATH` otherwise); `""` is the root itself. Nothing
 * outside the root is ever listed, read, written or deleted. Blocking: call off the main thread.
 */
interface FileTree {
    val root: RootInfo

    fun list(path: String): TreeResult<List<EntryInfo>>
    fun stat(path: String): TreeResult<EntryInfo>
    fun mkdir(path: String): TreeResult<EntryInfo>

    /** Recursive; never follows links (a link goes, its target stays). The root itself is `BAD_PATH`. */
    fun delete(path: String): TreeResult<Unit>
    fun rename(path: String, newName: String): TreeResult<EntryInfo>

    /** The file, opened now. It is [java.io.Closeable]: the caller closes it when its transfer ends. */
    fun openRead(path: String): TreeResult<OutgoingFile>

    /**
     * A hidden `.<uuid>.part` in [dirPath], renamed to [name] on commit: over the old file with
     * [overwrite], else with the SPEC 16 counter on a collision.
     */
    fun openWrite(dirPath: String, name: String, overwrite: Boolean): TreeResult<IncomingFile>

    /** Bytes that can be written under [dirPath]; null when unknown. */
    fun freeBytes(dirPath: String): Long? = null
}

/** The roots browsing may use now. */
fun interface RootsSource {
    fun trees(): List<FileTree>
}

/** The engine's in-progress files, `.<uuid>.part`: never listed. */
internal val PART_NAME = Regex("""\.[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.part""")
