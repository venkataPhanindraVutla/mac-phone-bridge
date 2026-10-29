package io.github.anmirror.feature.browse

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.github.anmirror.protocol.v1.BrowseOutcome
import io.github.anmirror.transfer.FileNames
import io.github.anmirror.transfer.IncomingFile
import io.github.anmirror.transfer.OutgoingFile
import java.io.Closeable
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

/**
 * A folder the user picked (`ACTION_OPEN_DOCUMENT_TREE`, persisted read and write). The provider
 * scopes every document to the tree, so nothing outside it is reachable; paths still go through
 * [BrowsePaths.segments]. Each segment is resolved by listing the parent's children ([DocPaths]);
 * the path → document ID map lives as long as this tree (one connection session: the app builds
 * new trees for each), every cached segment is checked on use, and mkdir, rename, delete and write
 * drop the entries they touch.
 *
 * A `SecurityException` is `REVOKED` only when the persisted grant is really gone
 * ([securityOutcome]); otherwise `IO`, and the folder stays. Free space: a folder on the primary
 * shared volume reports [primaryFree] (StorageManager, as for Downloads); elsewhere a write's part
 * document reports its volume's free space ([SpaceAware], `fstatvfs` on its descriptor).
 * Blocking: call off the main thread.
 */
class SafFileTree(
    context: Context,
    private val treeUri: Uri,
    override val root: RootInfo,
    private val primaryFree: () -> Long? = { null },
) : FileTree {
    private val resolver: ContentResolver = context.contentResolver
    private val rootDocId: String = DocumentsContract.getTreeDocumentId(treeUri)
    private val primary = usesPrimaryVolume(treeUri.authority, rootDocId)
    private val paths = DocPaths(rootDocId, ::children, ::query, { it.id }, { it.name })

    private class Doc(val id: String, val name: String, val mime: String, val size: Long, val modified: Long) {
        val isDir get() = mime == Document.MIME_TYPE_DIR
    }

    override fun list(path: String): TreeResult<List<EntryInfo>> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        val dir = paths.find(segments) ?: return@guard notFound
        if (!dir.isDir) return@guard badPath
        val entries = children(dir.id).filterNot { PART_NAME.matches(it.name) }.map { child ->
            paths.remember(join(path, child.name), child.id)
            child.toEntry(child.name)
        }
        TreeResult.Ok(entries)
    }

    override fun stat(path: String): TreeResult<EntryInfo> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        val doc = paths.find(segments) ?: return@guard notFound
        TreeResult.Ok(doc.toEntry(segments.lastOrNull() ?: root.name))
    }

    override fun mkdir(path: String): TreeResult<EntryInfo> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        if (segments.isEmpty()) return@guard badPath
        val name = segments.last()
        if (name != FileNames.sanitize(name)) return@guard badPath
        val parent = paths.find(segments.dropLast(1)) ?: return@guard notFound
        if (!parent.isDir) return@guard notFound
        // Shared storage is case-insensitive, and the provider would quietly pick "name (1)".
        if (children(parent.id).any { FileNames.key(it.name) == FileNames.key(name) }) return@guard exists
        val uri = DocumentsContract.createDocument(resolver, docUri(parent.id), Document.MIME_TYPE_DIR, name)
            ?: return@guard io
        paths.invalidate(path)
        val made = query(DocumentsContract.getDocumentId(uri)) ?: return@guard io
        TreeResult.Ok(made.toEntry(made.name))
    }

    override fun delete(path: String): TreeResult<Unit> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        if (segments.isEmpty()) return@guard badPath
        val doc = paths.find(segments) ?: return@guard notFound
        // The provider deletes a folder with everything in it. Shared storage has no symlinks to follow.
        val deleted = DocumentsContract.deleteDocument(resolver, docUri(doc.id))
        paths.invalidate(path)
        if (deleted) TreeResult.Ok(Unit) else io
    }

    override fun rename(path: String, newName: String): TreeResult<EntryInfo> = guard {
        if (newName.isEmpty() || newName != FileNames.sanitize(newName)) return@guard badPath
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        if (segments.isEmpty()) return@guard badPath
        val doc = paths.find(segments) ?: return@guard notFound
        if (newName == doc.name) return@guard TreeResult.Ok(doc.toEntry(newName))
        val parentId = paths.find(segments.dropLast(1))?.id ?: return@guard notFound
        val taken = children(parentId).any { it.id != doc.id && FileNames.key(it.name) == FileNames.key(newName) }
        if (taken) return@guard exists
        val renamed = DocumentsContract.renameDocument(resolver, docUri(doc.id), newName)
        paths.invalidate(path)
        val id = renamed?.let(DocumentsContract::getDocumentId) ?: doc.id
        val now = query(id) ?: return@guard io
        TreeResult.Ok(now.toEntry(now.name))
    }

    override fun openRead(path: String): TreeResult<OutgoingFile> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        val doc = paths.find(segments) ?: return@guard notFound
        if (doc.isDir) return@guard badPath
        val pfd = resolver.openFileDescriptor(docUri(doc.id), "r") ?: return@guard io
        val size = pfd.statSize.takeIf { it >= 0 } ?: doc.size
        val name = segments.last()
        TreeResult.Ok(OpenedDocument(name, size, doc.mime.ifEmpty { OCTET_STREAM }, doc.modified, pfd))
    }

    override fun openWrite(dirPath: String, name: String, overwrite: Boolean): TreeResult<IncomingFile> = guard {
        val segments = BrowsePaths.segments(dirPath) ?: return@guard badPath
        val dir = paths.find(segments) ?: return@guard notFound
        if (!dir.isDir) return@guard badPath
        val clean = FileNames.sanitize(name)
        if (overwrite && children(dir.id).any { it.isDir && FileNames.key(it.name) == FileNames.key(clean) }) return@guard exists
        // octet-stream: the provider keeps the name as given (no extension added).
        val part = DocumentsContract.createDocument(resolver, docUri(dir.id), OCTET_STREAM, partName()) ?: return@guard io
        val pfd = try {
            resolver.openFileDescriptor(part, "w") ?: throw IOException("no descriptor")
        } catch (e: Exception) {
            runCatching { DocumentsContract.deleteDocument(resolver, part) }
            throw e
        }
        TreeResult.Ok(PartDocument(dirPath, dir.id, part, clean, overwrite, pfd))
    }

    override fun freeBytes(dirPath: String): Long? = if (primary) primaryFree() else null

    /** Received bytes in a hidden part document, put in place on [commit] by [placeFile]. */
    private inner class PartDocument(
        private val dirPath: String,
        private val dirId: String,
        @Volatile private var current: Uri,
        private val name: String,
        private val overwrite: Boolean,
        private val pfd: ParcelFileDescriptor,
    ) : IncomingFile, SpaceAware {
        override val output: OutputStream = ParcelFileDescriptor.AutoCloseOutputStream(pfd)

        /**
         * Off the primary volume: what the part's own volume has free. Unknown (null, so the write is
         * not refused) unless the descriptor is a regular file on a volume that reports blocks.
         */
        override fun freeBytes(): Long? {
            if (primary) return null // the engine already checked it against [primaryFree]
            return try {
                val regular = OsConstants.S_ISREG(Os.fstat(pfd.fileDescriptor).st_mode)
                val st = Os.fstatvfs(pfd.fileDescriptor)
                trustedFreeBytes(regular, st.f_blocks, st.f_bavail, st.f_frsize)
            } catch (e: ErrnoException) {
                null
            }
        }

        override fun commit(): String {
            output.close()
            val partId = DocumentsContract.getDocumentId(current)
            val siblings = children(dirId).filter { it.id != partId }
            val keys = siblings.mapTo(HashSet()) { FileNames.key(it.name) }
            val old = if (overwrite) siblings.firstOrNull { FileNames.key(it.name) == FileNames.key(name) } else null
            if (old != null && old.isDir) throw IOException("a folder has that name")
            val unique = FileNames.unique(name) { FileNames.key(it) in keys }
            val placed = if (old == null) {
                placeFile(docOps, partId, unique, oldId = null, spare = unique)
            } else {
                placeFile(docOps, partId, name, oldId = old.id, spare = unique)
            }
            // Placed: from here on nothing may throw, or the abort would delete the saved file.
            current = docUri(placed.id)
            paths.invalidate(join(dirPath, placed.name))
            paths.invalidate(join(dirPath, name))
            return runCatching { query(placed.id)?.name }.getOrNull() ?: placed.name
        }

        /** Also after a [commit] that threw: the document goes, whatever it is called by now. */
        override fun abort() {
            runCatching { output.close() }
            DocumentsContract.deleteDocument(resolver, current)
        }
    }

    private val docOps = object : DocOps {
        override fun rename(id: String, name: String): String {
            val renamed = DocumentsContract.renameDocument(resolver, docUri(id), name)
            return renamed?.let(DocumentsContract::getDocumentId) ?: id
        }

        override fun delete(id: String) {
            if (!DocumentsContract.deleteDocument(resolver, docUri(id))) throw IOException("delete refused")
        }
    }

    /** An opened document to send; [close] releases it if the transfer never read it. */
    private class OpenedDocument(
        override val name: String,
        override val size: Long,
        override val mime: String,
        override val modifiedMs: Long,
        private val pfd: ParcelFileDescriptor,
    ) : OutgoingFile, Closeable {
        override fun open(): InputStream = ParcelFileDescriptor.AutoCloseInputStream(pfd)
        override fun close() = pfd.close()
    }

    // ---- resolving -------------------------------------------------------------------------

    private fun children(parentId: String): List<Doc> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        return resolver.query(uri, PROJECTION, null, null, null)?.use { c ->
            val out = ArrayList<Doc>(c.count.coerceAtLeast(0))
            while (c.moveToNext()) out += c.doc()
            out
        } ?: throw IOException("no cursor")
    }

    private fun query(id: String): Doc? =
        resolver.query(docUri(id), PROJECTION, null, null, null)?.use { c -> if (c.moveToFirst()) c.doc() else null }

    private fun Cursor.doc() = Doc(
        id = getString(0),
        name = getString(1).orEmpty(),
        mime = getString(2).orEmpty(),
        size = if (isNull(3)) 0 else getLong(3),
        modified = if (isNull(4)) 0 else getLong(4),
    )

    private fun Doc.toEntry(shownAs: String) = EntryInfo(
        name = shownAs,
        isDir = isDir,
        size = if (isDir) 0 else size.coerceAtLeast(0),
        modifiedMs = modified,
        mime = if (isDir) "" else mime.ifEmpty { OCTET_STREAM },
    )

    private fun docUri(id: String): Uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)

    /** The persisted grants now; null when they can't be read. */
    private fun grants(): List<Grant>? = try {
        resolver.persistedUriPermissions.map { Grant(it.uri.toString(), it.isReadPermission, it.isWritePermission) }
    } catch (e: RuntimeException) {
        null
    }

    private fun join(dir: String, name: String) = if (dir.isEmpty()) name else "$dir/$name"

    private fun partName() = ".${UUID.randomUUID()}.part"

    private inline fun <T> guard(body: () -> TreeResult<T>): TreeResult<T> = try {
        body()
    } catch (e: SecurityException) {
        TreeResult.Err(securityOutcome(treeUri.toString(), grants()))
    } catch (e: FileNotFoundException) {
        notFound
    } catch (e: IllegalArgumentException) {
        notFound // a document ID the provider no longer knows
    } catch (e: UnsupportedOperationException) {
        TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_DENIED)
    } catch (e: IOException) {
        io
    } catch (e: IllegalStateException) {
        io
    }

    private companion object {
        const val OCTET_STREAM = "application/octet-stream"
        val PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
        )
        val badPath = TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH)
        val notFound = TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND)
        val exists = TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_EXISTS)
        val io = TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_IO)
    }
}
