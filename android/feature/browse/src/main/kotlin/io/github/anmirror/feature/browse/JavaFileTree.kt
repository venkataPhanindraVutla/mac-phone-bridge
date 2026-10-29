package io.github.anmirror.feature.browse

import io.github.anmirror.protocol.v1.BrowseOutcome
import io.github.anmirror.transfer.FileNames
import io.github.anmirror.transfer.IncomingFile
import io.github.anmirror.transfer.OutgoingFile
import java.io.Closeable
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.AccessDeniedException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.NotDirectoryException
import java.nio.file.Path
import java.nio.file.SecureDirectoryStream
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributeView
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID

/**
 * A browse root on the file system: All files access (`Environment.getExternalStorageDirectory()`).
 *
 * Path safety: every path goes through [BrowsePaths.segments], then is resolved to its canonical
 * form, which must be the root or lie under it (`BAD_PATH` otherwise). Operations act on that
 * checked canonical path. [delete] and [rename] resolve only the parent that way and act on the
 * last segment itself, without following it, so a link is deleted or renamed, never its target.
 * Links whose target leaves the root (or is missing) are not listed and answer `BAD_PATH`.
 *
 * Against a folder swapped for a link between the check and the use ([Descriptors]):
 * - reads open with `O_NOFOLLOW`, and on Android the opened descriptor's real path
 *   (`/proc/self/fd`) must lie under the root, else it is closed and the read is `BAD_PATH`;
 * - a write's hidden `.<uuid>.part` is created with `O_CREAT | O_EXCL | O_NOFOLLOW` in the checked
 *   folder; on commit, right before the rename, the part's descriptor must still be in that
 *   folder and the folder's path must still resolve to itself. The abort deletes the part where
 *   its descriptor says it is (its random name can only be ours);
 * - delete removes entries through a [SecureDirectoryStream] (`openat`/`unlinkat`) where the
 *   platform has one, else by walking the tree without following links.
 *
 * Java has no `renameat`, so a rename (and mkdir, and the walk) still goes by path: a swap in the
 * instant between the last check and the call is not covered. That remaining window rests on
 * Android shared storage (`/storage/emulated`, FUSE) refusing to create symlinks, so no app can
 * plant one there. On the JVM test host the platform opener is [NioDescriptors], which can't see
 * a descriptor's real path; the tests stand in for it, and the `/proc` path runs on devices only.
 */
class JavaFileTree internal constructor(
    rootDir: File,
    override val root: RootInfo,
    private val mimeFor: (String) -> String,
    private val free: () -> Long?,
    private val fds: Descriptors,
    private val log: (String) -> Unit = {},
) : FileTree {
    constructor(
        rootDir: File,
        root: RootInfo,
        mimeFor: (String) -> String,
        free: () -> Long? = { null },
        log: (String) -> Unit = {},
    ) : this(rootDir, root, mimeFor, free, Descriptors.platform(), log)

    private val rootCanon: File = rootDir.canonicalFile
    private val rootPrefix = rootCanon.path.trimEnd(File.separatorChar) + File.separatorChar

    override fun list(path: String): TreeResult<List<EntryInfo>> = guard {
        val dir = when (val r = resolve(path)) {
            is TreeResult.Err -> return@guard r
            is TreeResult.Ok -> r.value
        }
        if (!dir.exists()) return@guard notFound
        if (!dir.isDirectory) return@guard badPath
        val names = dir.list() ?: return@guard denied
        val entries = names.mapNotNull { name ->
            if (PART_NAME.matches(name)) return@mapNotNull null
            try {
                val child = File(dir, name)
                val target = if (isLink(child)) visibleTarget(child) ?: return@mapNotNull null else child
                entry(name, target)
            } catch (e: IOException) {
                null // gone meanwhile, or unreadable: not listed
            }
        }
        TreeResult.Ok(entries)
    }

    override fun stat(path: String): TreeResult<EntryInfo> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        val file = when (val r = resolve(path)) {
            is TreeResult.Err -> return@guard r
            is TreeResult.Ok -> r.value
        }
        if (!file.exists()) return@guard notFound
        TreeResult.Ok(entry(segments.lastOrNull() ?: root.name, file))
    }

    override fun mkdir(path: String): TreeResult<EntryInfo> = guard {
        val (parent, name) = when (val r = resolveLeaf(path)) {
            is TreeResult.Err -> return@guard r
            is TreeResult.Ok -> r.value
        }
        if (name != FileNames.sanitize(name)) return@guard badPath
        val target = File(parent, name)
        if (exists(target)) return@guard TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_EXISTS)
        if (!stillChecked(parent)) return@guard badPath
        try {
            Files.createDirectory(target.toPath()) // mkdir(2): never through a link at the last segment
        } catch (e: FileAlreadyExistsException) {
            return@guard TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_EXISTS)
        }
        TreeResult.Ok(entry(name, target))
    }

    override fun delete(path: String): TreeResult<Unit> = guard {
        val (parent, name) = when (val r = resolveLeaf(path)) {
            is TreeResult.Err -> return@guard r
            is TreeResult.Ok -> r.value
        }
        val target = File(parent, name)
        if (!exists(target)) return@guard notFound
        if (isLink(target) && visibleTarget(target) == null) return@guard badPath
        if (!stillChecked(parent)) return@guard badPath
        Files.newDirectoryStream(parent.toPath()).use { stream ->
            // Opened: the folder must still be the one checked; from here on nothing goes by path.
            if (stream is SecureDirectoryStream<Path> && stillChecked(parent)) {
                deleteBelow(stream, target.toPath().fileName)
                return@guard TreeResult.Ok(Unit)
            }
        }
        // No SecureDirectoryStream (the JVM test host; maybe Android): no FOLLOW_LINKS, so a link
        // (at the top or anywhere below) is visited as a file and deleted itself.
        Files.walkFileTree(
            target.toPath(),
            object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    Files.delete(file)
                    return FileVisitResult.CONTINUE
                }

                override fun postVisitDirectory(dir: Path, exc: IOException?): FileVisitResult {
                    if (exc != null) throw exc
                    Files.delete(dir)
                    return FileVisitResult.CONTINUE
                }

                override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult = throw exc
            },
        )
        TreeResult.Ok(Unit)
    }

    override fun rename(path: String, newName: String): TreeResult<EntryInfo> = guard {
        if (newName.isEmpty() || newName != FileNames.sanitize(newName)) return@guard badPath
        val (parent, name) = when (val r = resolveLeaf(path)) {
            is TreeResult.Err -> return@guard r
            is TreeResult.Ok -> r.value
        }
        val source = File(parent, name)
        if (!exists(source)) return@guard notFound
        if (isLink(source) && visibleTarget(source) == null) return@guard badPath
        val dest = File(parent, newName)
        if (newName != name) {
            // Only a change of case may land on "itself" (a case-insensitive volume); anything else is taken.
            val caseOnly = FileNames.key(newName) == FileNames.key(name)
            if (exists(dest) && !(caseOnly && Files.isSameFile(source.toPath(), dest.toPath()))) {
                return@guard TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_EXISTS)
            }
            if (!stillChecked(parent)) return@guard badPath
            if (caseOnly) {
                // Files.move treats a case-only rename as a no-op: go through a hidden temporary name.
                renameThrough(source.toPath(), File(parent, partName()).toPath(), dest.toPath())
            } else {
                Files.move(source.toPath(), dest.toPath()) // a link moves itself; never replaces
            }
        }
        TreeResult.Ok(entry(newName, dest))
    }

    override fun openRead(path: String): TreeResult<OutgoingFile> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        val file = when (val r = resolve(path)) {
            is TreeResult.Err -> return@guard r
            is TreeResult.Ok -> r.value
        }
        if (!file.exists()) return@guard notFound
        if (!file.isFile) return@guard badPath
        val attrs = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
        val handle = try {
            fds.openRead(file)
        } catch (e: IOException) {
            // O_NOFOLLOW: the file became a link since the check.
            if (e is LinkRefused || isLink(file)) return@guard badPath
            throw e
        }
        // Opened: the descriptor (or, where the system can't tell, the path) must still be in the root.
        val inside = handle.realPath?.let(::realInRoot) ?: stillChecked(file)
        if (!inside) {
            handle.close()
            return@guard badPath
        }
        val name = segments.last()
        TreeResult.Ok(OpenedFile(name, handle.size, mimeFor(name), attrs.lastModifiedTime().toMillis(), handle))
    }

    override fun openWrite(dirPath: String, name: String, overwrite: Boolean): TreeResult<IncomingFile> = guard {
        val dir = when (val r = resolve(dirPath)) {
            is TreeResult.Err -> return@guard r
            is TreeResult.Ok -> r.value
        }
        if (!dir.exists()) return@guard notFound
        if (!dir.isDirectory) return@guard badPath
        val clean = FileNames.sanitize(name)
        if (overwrite) {
            val old = File(dir, clean)
            if (exists(old)) {
                if (isLink(old) && visibleTarget(old) == null) return@guard badPath
                if (old.isDirectory) return@guard TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_EXISTS)
            }
        }
        val partFile = PartFile(dir, File(dir, partName()), clean, overwrite, fds)
        if (!partFile.inPlace()) {
            partFile.abort()
            return@guard badPath
        }
        TreeResult.Ok(partFile)
    }

    /** [free]: the app passes StorageManager's allocatable bytes for the shared volume. */
    override fun freeBytes(dirPath: String): Long? = free()

    /** Received bytes in a hidden part file, renamed into place on [commit]. */
    private inner class PartFile(
        private val dir: File,
        private val part: File,
        private val name: String,
        private val overwrite: Boolean,
        fds: Descriptors,
    ) : IncomingFile {
        private val handle = fds.createNew(part) // O_CREAT | O_EXCL | O_NOFOLLOW
        override val output: OutputStream = handle.output

        /** The part is (still) in the checked folder, and that folder's path still resolves to itself. */
        fun inPlace(): Boolean {
            val real = handle.realPath()
            if (real != null && File(real).parent != realFormOf(dir)) return false
            return stillChecked(dir)
        }

        override fun commit(): String {
            // Right before the rename: the part must still be where it was checked.
            if (!inPlace()) throw IOException("destination folder changed")
            output.close()
            val saved = if (overwrite) {
                val old = File(dir, name)
                if (exists(old) && !isLink(old) && old.isDirectory) throw IOException("a folder has that name")
                name
            } else {
                val keys = dir.list().orEmpty().mapTo(HashSet(), FileNames::key)
                FileNames.unique(name) { FileNames.key(it) in keys }
            }
            val target = File(dir, saved).toPath()
            if (overwrite) {
                // rename(2): replaces an old file (or a link itself, never its target).
                Files.move(part.toPath(), target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            } else {
                Files.move(part.toPath(), target) // never replaces: a name taken meanwhile fails the write
            }
            return saved
        }

        /**
         * Also after a [commit] that threw. The part's name is a fresh random one, so deleting it
         * can only ever remove our own file, wherever the path leads now.
         */
        override fun abort() {
            val real = runCatching { handle.realPath() }.getOrNull()?.let(::File)?.takeIf { it.name == part.name }
            runCatching { output.close() }
            Files.deleteIfExists((real ?: part).toPath())
        }
    }

    /** An opened file to send; [close] releases it if the transfer never read it. */
    private class OpenedFile(
        override val name: String,
        override val size: Long,
        override val mime: String,
        override val modifiedMs: Long,
        private val handle: ReadHandle,
    ) : OutgoingFile, Closeable {
        override fun open(): InputStream = handle.input
        override fun close() = handle.close()
    }

    /** Deletes [name] in [dir] and, for a folder, everything in it, all through descriptors: no link is followed. */
    private fun deleteBelow(dir: SecureDirectoryStream<Path>, name: Path) {
        val attrs = dir.getFileAttributeView(name, BasicFileAttributeView::class.java, LinkOption.NOFOLLOW_LINKS).readAttributes()
        if (attrs.isDirectory) {
            dir.newDirectoryStream(name, LinkOption.NOFOLLOW_LINKS).use { child ->
                for (entry in child.map { it.fileName }.toList()) deleteBelow(child, entry)
            }
            dir.deleteDirectory(name)
        } else {
            dir.deleteFile(name) // a link goes itself
        }
    }

    // ---- resolving -------------------------------------------------------------------------

    private fun inRoot(f: File): Boolean = f.path == rootCanon.path || f.path.startsWith(rootPrefix)

    /**
     * The root as descriptors report paths ([Descriptors.realDirPath]): the same mount namespace
     * and kernel path form (`/storage/emulated/0`, `/mnt/user/0/emulated/0`, `/data/media/0`) as a
     * file's real path. Read once; when the system can't tell, the canonical path.
     */
    private val realRoot: String by lazy {
        fds.realDirPath(rootCanon)?.trimEnd(File.separatorChar)?.ifEmpty { null } ?: run {
            log("browse: root real path unknown, using the canonical path")
            rootCanon.path.trimEnd(File.separatorChar)
        }
    }

    /** A descriptor's real path lies in the root. */
    private fun realInRoot(real: String): Boolean = real == realRoot || real.startsWith(realRoot + File.separatorChar)

    /** [checked] (a canonical path in the root) in the form descriptors report. */
    private fun realFormOf(checked: File): String = realRoot + checked.path.removePrefix(rootCanon.path.trimEnd(File.separatorChar))

    /** Every segment followed: the canonical file, which must be in the root. */
    private fun resolve(path: String): TreeResult<File> {
        val segments = BrowsePaths.segments(path) ?: return badPath
        val canon = segments.fold(rootCanon) { f, s -> File(f, s) }.canonicalFile
        return if (inRoot(canon)) TreeResult.Ok(canon) else badPath
    }

    /** The canonical, checked parent and the last segment, not followed. The root itself is `BAD_PATH`. */
    private fun resolveLeaf(path: String): TreeResult<Pair<File, String>> {
        val segments = BrowsePaths.segments(path) ?: return badPath
        if (segments.isEmpty()) return badPath
        val parent = when (val r = resolve(segments.dropLast(1).joinToString("/"))) {
            is TreeResult.Err -> return r
            is TreeResult.Ok -> r.value
        }
        if (!parent.isDirectory) return notFound
        return TreeResult.Ok(parent to segments.last())
    }

    /** [checked] (a canonical path in the root) still resolves to itself: nothing on the way became a link. */
    private fun stillChecked(checked: File): Boolean = try {
        checked.canonicalFile == checked && inRoot(checked)
    } catch (e: IOException) {
        false
    }

    /** A link's canonical target when it exists and is in the root; null when the link is not to be shown. */
    private fun visibleTarget(link: File): File? {
        val target = link.canonicalFile
        return target.takeIf { inRoot(it) && it.exists() }
    }

    private fun isLink(f: File) = Files.isSymbolicLink(f.toPath())

    private fun exists(f: File) = Files.exists(f.toPath(), LinkOption.NOFOLLOW_LINKS)

    private fun entry(name: String, file: File): EntryInfo {
        val attrs = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
        val dir = attrs.isDirectory
        return EntryInfo(
            name = name,
            isDir = dir,
            size = if (dir) 0 else attrs.size(),
            modifiedMs = attrs.lastModifiedTime().toMillis(),
            mime = if (dir) "" else mimeFor(name),
        )
    }

    private fun partName() = ".${UUID.randomUUID()}.part"

    private inline fun <T> guard(body: () -> TreeResult<T>): TreeResult<T> = try {
        body()
    } catch (e: NoSuchFileException) {
        notFound
    } catch (e: FileNotFoundException) {
        notFound
    } catch (e: NotDirectoryException) {
        badPath
    } catch (e: FileAlreadyExistsException) {
        TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_EXISTS)
    } catch (e: AccessDeniedException) {
        denied
    } catch (e: SecurityException) {
        denied
    } catch (e: IOException) {
        TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_IO)
    }

    private companion object {
        val badPath = TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH)
        val notFound = TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND)
        val denied = TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_DENIED)
    }
}

/**
 * Renames [source] to [dest] through [temp] (a case-only rename). If the second step fails, the
 * file goes back to [source].
 */
internal fun renameThrough(source: Path, temp: Path, dest: Path, move: (Path, Path) -> Unit = { a, b -> Files.move(a, b) }) {
    move(source, temp)
    try {
        move(temp, dest)
    } catch (e: Exception) {
        runCatching { move(temp, source) }
        throw e
    }
}
