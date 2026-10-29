package io.github.anmirror.feature.browse

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.github.anmirror.protocol.v1.RootKind
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.MessageDigest

/**
 * The folders the user picked for browsing (`ACTION_OPEN_DOCUMENT_TREE`), each with a persisted
 * read and write grant. Their tree URIs, display names and whether they take new files are kept in
 * private preferences; the names are shown on the phone and sent to the Mac, never logged.
 */
class PickedFolders(context: Context) {
    data class Folder(val uri: Uri, val root: RootInfo)

    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val lock = Any()
    private val _folders = MutableStateFlow(read())

    /** In the order they were added. */
    val folders: StateFlow<List<Folder>> = _folders.asStateFlow()

    /**
     * Takes the persisted grant for a just-picked [uri] and remembers the folder. Blocking (asks
     * the provider for the folder's name): call off the main thread. Null when the grant can't be
     * kept or the folder can't be read.
     */
    fun add(uri: Uri): Folder? {
        try {
            app.contentResolver.takePersistableUriPermission(uri, GRANT)
        } catch (e: SecurityException) {
            return null
        }
        val doc = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
        val (name, flags) = try {
            app.contentResolver.query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME, Document.COLUMN_FLAGS), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0).orEmpty() to c.getInt(1) else null }
        } catch (e: RuntimeException) {
            null
        } ?: run {
            release(uri)
            return null
        }
        val writable = flags and Document.FLAG_DIR_SUPPORTS_CREATE != 0
        val folder = Folder(uri, RootInfo(rootId(uri.toString()), name, RootKind.ROOT_KIND_PICKED_FOLDER, writable))
        synchronized(lock) {
            val keep = _folders.value.filter { it.root.id != folder.root.id } + folder
            write(keep)
        }
        return folder
    }

    /** Forgets the folder with [rootId] and gives its grant back. */
    fun remove(rootId: String) {
        val gone = synchronized(lock) {
            val all = _folders.value
            val gone = all.filter { it.root.id == rootId }
            if (gone.isNotEmpty()) write(all - gone.toSet())
            gone
        }
        gone.forEach { release(it.uri) }
    }

    /** Forgets folders whose grant is gone (revoked in Settings, say). Blocking. */
    fun prune() {
        val granted = try {
            app.contentResolver.persistedUriPermissions
                .filter { it.isReadPermission && it.isWritePermission }
                .mapTo(HashSet()) { it.uri.toString() }
        } catch (e: RuntimeException) {
            return
        }
        synchronized(lock) {
            val all = _folders.value
            val keep = all.filter { it.uri.toString() in granted }
            if (keep.size != all.size) write(keep)
        }
    }

    private fun release(uri: Uri) {
        try {
            app.contentResolver.releasePersistableUriPermission(uri, GRANT)
        } catch (e: SecurityException) {
            // Already gone.
        }
    }

    private fun read(): List<Folder> {
        val uris = prefs.getString(KEY_ORDER, null)?.split('\n')?.filter { it.isNotEmpty() }.orEmpty()
        return uris.map { s ->
            val id = rootId(s)
            val name = prefs.getString("$KEY_NAME$id", null).orEmpty()
            val writable = prefs.getBoolean("$KEY_WRITABLE$id", true)
            Folder(Uri.parse(s), RootInfo(id, name, RootKind.ROOT_KIND_PICKED_FOLDER, writable))
        }
    }

    /** Called under [lock]. */
    private fun write(folders: List<Folder>) {
        val editor = prefs.edit().clear()
        editor.putString(KEY_ORDER, folders.joinToString("\n") { it.uri.toString() })
        for (f in folders) {
            editor.putString("$KEY_NAME${f.root.id}", f.root.name)
            editor.putBoolean("$KEY_WRITABLE${f.root.id}", f.root.writable)
        }
        editor.apply()
        _folders.value = folders
    }

    companion object {
        private const val PREFS = "browse_folders"
        private const val KEY_ORDER = "uris"
        private const val KEY_NAME = "name."
        private const val KEY_WRITABLE = "writable."
        private const val GRANT = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

        /** A picked folder's root ID: the first 16 hex digits of SHA-256 of its tree URI. */
        fun rootId(treeUri: String): String =
            MessageDigest.getInstance("SHA-256").digest(treeUri.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
                .take(16)
    }
}
