package io.github.anmirror.feature.browse

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
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
import java.util.concurrent.ConcurrentHashMap

/**
 * A folder the user picked (`ACTION_OPEN_DOCUMENT_TREE`, persisted read and write). The provider
 * scopes every document to the tree, so nothing outside it is reachable; paths still go through
 * [BrowsePaths.segments]. Each segment is resolved by listing the parent's children, and the
 * path → document ID map is kept for this tree's life (one connection session; the app builds new
 * trees for each); mkdir, rename, delete and write drop the entries they touch, and a stale entry
 * is dropped and looked up again. A `SecurityException` (the grant is gone) is `REVOKED`.
 * Blocking: call off the main thread.
 */
class SafFileTree(context: Context, private val treeUri: Uri, override val root: RootInfo) : FileTree {
    private val resolver: ContentResolver = context.contentResolver
    private val rootDocId: String = DocumentsContract.getTreeDocumentId(treeUri)
    private val ids = ConcurrentHashMap<String, String>()

    private class Doc(val id: String, val name: String, val mime: String, val size: Long, val modified: Long) {
        val isDir get() = mime == Document.MIME_TYPE_DIR
    }

    override fun list(path: String): TreeResult<List<EntryInfo>> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        val dir = find(segments) ?: return@guard notFound
        if (!dir.isDir) return@guard badPath
        val entries = children(dir.id).filterNot { PART_NAME.matches(it.name) }.map { child ->
            ids[join(path, child.name)] = child.id
            child.toEntry(child.name)
        }
        TreeResult.Ok(entries)
    }

    override fun stat(path: String): TreeResult<EntryInfo> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        val doc = find(segments) ?: return@guard notFound
        TreeResult.Ok(doc.toEntry(segments.lastOrNull() ?: root.name))
    }

    override fun mkdir(path: String): TreeResult<EntryInfo> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        if (segments.isEmpty()) return@guard badPath
        val name = segments.last()
        if (name != FileNames.sanitize(name)) return@guard badPath
        val parent = find(segments.dropLast(1)) ?: return@guard notFound
        if (!parent.isDir) return@guard notFound
        // Shared storage is case-insensitive, and the provider would quietly pick "name (1)".
        if (children(parent.id).any { FileNames.key(it.name) == FileNames.key(name) }) return@guard exists
        val uri = DocumentsContract.createDocument(resolver, docUri(parent.id), Document.MIME_TYPE_DIR, name)
            ?: return@guard io
        invalidate(path)
        val made = query(DocumentsContract.getDocumentId(uri)) ?: return@guard io
        TreeResult.Ok(made.toEntry(made.name))
    }

    override fun delete(path: String): TreeResult<Unit> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        if (segments.isEmpty()) return@guard badPath
        val doc = find(segments) ?: return@guard notFound
        // The provider deletes a folder with everything in it. Shared storage has no symlinks to follow.
        val deleted = DocumentsContract.deleteDocument(resolver, docUri(doc.id))
        invalidate(path)
        if (deleted) TreeResult.Ok(Unit) else io
    }

    override fun rename(path: String, newName: String): TreeResult<EntryInfo> = guard {
        if (newName.isEmpty() || newName != FileNames.sanitize(newName)) return@guard badPath
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        if (segments.isEmpty()) return@guard badPath
        val doc = find(segments) ?: return@guard notFound
        if (newName == doc.name) return@guard TreeResult.Ok(doc.toEntry(newName))
        val parentId = find(segments.dropLast(1))?.id ?: return@guard notFound
        val taken = children(parentId).any { it.id != doc.id && FileNames.key(it.name) == FileNames.key(newName) }
        if (taken) return@guard exists
        val renamed = DocumentsContract.renameDocument(resolver, docUri(doc.id), newName)
        invalidate(path)
        val id = renamed?.let(DocumentsContract::getDocumentId) ?: doc.id
        val now = query(id) ?: return@guard io
        TreeResult.Ok(now.toEntry(now.name))
    }

    override fun openRead(path: String): TreeResult<OutgoingFile> = guard {
        val segments = BrowsePaths.segments(path) ?: return@guard badPath
        val doc = find(segments) ?: return@guard notFound
        if (doc.isDir) return@guard badPath
        val pfd = resolver.openFileDescriptor(docUri(doc.id), "r") ?: return@guard io
        val size = pfd.statSize.takeIf { it >= 0 } ?: doc.size
        val name = segments.last()
        TreeResult.Ok(OpenedDocument(name, size, doc.mime.ifEmpty { OCTET_STREAM }, doc.modified, pfd))
    }

    override fun openWrite(dirPath: String, name: String, overwrite: Boolean): TreeResult<IncomingFile> = guard {
        val segments = BrowsePaths.segments(dirPath) ?: return@guard badPath
        val dir = find(segments) ?: return@guard notFound
        if (!dir.isDir) return@guard badPath
        val clean = FileNames.sanitize(name)
        if (overwrite && children(dir.id).any { it.isDir && FileNames.key(it.name) == FileNames.key(clean) }) return@guard exists
        // octet-stream: the provider keeps the name as given (no extension added).
        val part = DocumentsContract.createDocument(resolver, docUri(dir.id), OCTET_STREAM, partName()) ?: return@guard io
        val out = try {
            resolver.openOutputStream(part, "w") ?: throw IOException("no output stream")
        } catch (e: Exception) {
            runCatching { DocumentsContract.deleteDocument(resolver, part) }
            throw e
        }
        TreeResult.Ok(PartDocument(dirPath, dir.id, part, clean, overwrite, out))
    }

    /** Received bytes in a hidden part document, renamed into place on [commit]. */
    private inner class PartDocument(
        private val dirPath: String,
        private val dirId: String,
        @Volatile private var current: Uri,
        private val name: String,
        private val overwrite: Boolean,
        override val output: OutputStream,
    ) : IncomingFile {
        override fun commit(): String {
            output.close()
            val partId = DocumentsContract.getDocumentId(current)
            val siblings = children(dirId).filter { it.id != partId }
            val saved: String
            var old: Uri? = null
            if (overwrite) {
                val existing = siblings.firstOrNull { FileNames.key(it.name) == FileNames.key(name) }
                if (existing != null) {
                    if (existing.isDir) throw IOException("a folder has that name")
                    // Moved aside, not deleted, until the new file has its name.
                    old = DocumentsContract.renameDocument(resolver, docUri(existing.id), partName()) ?: docUri(existing.id)
                }
                saved = name
            } else {
                val keys = siblings.mapTo(HashSet()) { FileNames.key(it.name) }
                saved = FileNames.unique(name) { FileNames.key(it) in keys }
            }
            val placed = try {
                DocumentsContract.renameDocument(resolver, current, saved)
            } catch (e: Exception) {
                old?.let { runCatching { DocumentsContract.renameDocument(resolver, it, name) } }
                throw e
            }
            if (placed != null) current = placed
            old?.let { runCatching { DocumentsContract.deleteDocument(resolver, it) } }
            invalidate(join(dirPath, saved))
            invalidate(join(dirPath, name))
            // Nothing below may throw: an abort now would delete the saved file.
            return runCatching { query(DocumentsContract.getDocumentId(current))?.name }.getOrNull() ?: saved
        }

        /** Also after a [commit] that threw: the document goes, whatever it is called by now. */
        override fun abort() {
            runCatching { output.close() }
            DocumentsContract.deleteDocument(resolver, current)
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

    /**
     * The document at [segments], or null when there is none. Cached IDs are tried first; when
     * that finds nothing (an ID went stale: renamed or deleted on the phone), the path is looked
     * up again from the root.
     */
    private fun find(segments: List<String>): Doc? {
        if (segments.isEmpty()) return query(rootDocId)
        val cached = try {
            walk(segments, useCache = true)
        } catch (e: FileNotFoundException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        }
        return cached ?: walk(segments, useCache = false)
    }

    private fun walk(segments: List<String>, useCache: Boolean): Doc? {
        var parentId = rootDocId
        var at = ""
        for ((i, segment) in segments.withIndex()) {
            at = join(at, segment)
            val last = i == segments.lastIndex
            val cached = if (useCache) ids[at] else null
            if (cached != null) {
                if (!last) {
                    parentId = cached
                    continue
                }
                return query(cached)?.takeIf { it.name == segment }
            }
            val child = children(parentId).firstOrNull { it.name == segment } ?: return null
            ids[at] = child.id
            if (last) return child
            parentId = child.id
        }
        return null
    }

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

    /** Forgets [path] and everything under it. */
    private fun invalidate(path: String) {
        ids.keys.removeIf { it == path || it.startsWith("$path/") }
    }

    private fun join(dir: String, name: String) = if (dir.isEmpty()) name else "$dir/$name"

    private fun partName() = ".${UUID.randomUUID()}.part"

    private inline fun <T> guard(body: () -> TreeResult<T>): TreeResult<T> = try {
        body()
    } catch (e: SecurityException) {
        TreeResult.Err(BrowseOutcome.BROWSE_OUTCOME_REVOKED)
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
