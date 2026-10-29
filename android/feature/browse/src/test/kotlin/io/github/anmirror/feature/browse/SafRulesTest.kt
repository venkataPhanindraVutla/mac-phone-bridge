package io.github.anmirror.feature.browse

import io.github.anmirror.protocol.v1.BrowseOutcome
import java.io.FileNotFoundException
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A folder of documents: ID → (name, content). Names starting with "." are hidden. */
private class FakeFolder(vararg docs: Pair<String, Pair<String, String>>) : DocOps {
    val docs = linkedMapOf(*docs)
    var failRenameTo: String? = null
    var failDelete = false
    private var next = 100

    override fun rename(id: String, name: String): String {
        if (name == failRenameTo) throw IOException("rename refused")
        val (_, content) = docs.remove(id) ?: throw FileNotFoundException(id)
        val newId = "d${next++}" // like ExternalStorageProvider: the ID follows the name
        docs[newId] = name to content
        return newId
    }

    override fun delete(id: String) {
        if (failDelete) throw IOException("delete refused")
        docs.remove(id) ?: throw FileNotFoundException(id)
    }

    fun visible() = docs.values.filter { !it.first.startsWith(".") }.toMap()
    fun hidden() = docs.values.filter { it.first.startsWith(".") }
}

class SafRulesTest {
    private fun folder() = FakeFolder("old" to ("report.txt" to "OLD"), "part" to (".p.part" to "NEW"))

    @Test fun overwriteReplacesTheOldFile() {
        val f = folder()
        val placed = placeFile(f, "part", "report.txt", oldId = "old", spare = "report (1).txt")
        assertEquals("report.txt", placed.name)
        assertEquals(mapOf("report.txt" to "NEW"), f.visible())
        assertTrue(f.hidden().isEmpty())
    }

    @Test fun overwriteFailingAtStep1KeepsTheOldFileVisible() {
        val f = folder().apply { failRenameTo = "report (1).txt" }
        assertFailsWith<IOException> { placeFile(f, "part", "report.txt", oldId = "old", spare = "report (1).txt") }
        // The old file is untouched; the part is still hidden, and the engine's abort deletes it.
        assertEquals(mapOf("report.txt" to "OLD"), f.visible())
    }

    @Test fun overwriteFailingAtStep2KeepsBothVisible() {
        val f = folder().apply { failDelete = true }
        val placed = placeFile(f, "part", "report.txt", oldId = "old", spare = "report (1).txt")
        assertEquals("report (1).txt", placed.name)
        assertEquals(mapOf("report.txt" to "OLD", "report (1).txt" to "NEW"), f.visible())
        assertTrue(f.hidden().isEmpty())
    }

    @Test fun overwriteFailingAtStep3LeavesTheNewFileVisibleUnderTheSpareName() {
        val f = folder().apply { failRenameTo = "report.txt" }
        val placed = placeFile(f, "part", "report.txt", oldId = "old", spare = "report (1).txt")
        assertEquals("report (1).txt", placed.name)
        assertEquals(mapOf("report (1).txt" to "NEW"), f.visible())
        assertTrue(f.hidden().isEmpty())
    }

    @Test fun plainWriteIsOneRename() {
        val f = FakeFolder("part" to (".p.part" to "NEW"))
        assertEquals("a.txt", placeFile(f, "part", "a.txt", oldId = null, spare = "unused").name)
        assertEquals(mapOf("a.txt" to "NEW"), f.visible())
    }

    @Test fun primaryVolumeIsExternalStoragePrimary() {
        assertTrue(usesPrimaryVolume("com.android.externalstorage.documents", "primary:Documents"))
        assertTrue(usesPrimaryVolume("com.android.externalstorage.documents", "primary:"))
        assertFalse(usesPrimaryVolume("com.android.externalstorage.documents", "1234-5678:Music"))
        assertFalse(usesPrimaryVolume("com.google.android.apps.docs.storage", "primary:x"))
        assertFalse(usesPrimaryVolume(null, "primary:x"))
    }

    @Test fun roomIsSizePlus64MiB() {
        val mib = 1L shl 20
        assertTrue(fitsFreeSpace(size = 10 * mib, free = 74 * mib))
        assertFalse(fitsFreeSpace(size = 10 * mib + 1, free = 74 * mib))
        assertTrue(fitsFreeSpace(size = 1L shl 40, free = null), "unknown free space: take it")
    }

    @Test fun securityExceptionIsRevokedOnlyWhenTheGrantIsGone() {
        val tree = "content://com.android.externalstorage.documents/tree/primary%3ADocs"
        val other = "content://com.android.externalstorage.documents/tree/primary%3AMusic"
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_IO, securityOutcome(tree, listOf(Grant(tree, read = true, write = true))))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_REVOKED, securityOutcome(tree, listOf(Grant(other, read = true, write = true))))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_REVOKED, securityOutcome(tree, listOf(Grant(tree, read = true, write = false))))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_REVOKED, securityOutcome(tree, emptyList()))
        // The grants can't be read: keep the root.
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_IO, securityOutcome(tree, null))
    }
}

/** A provider tree: ID → (parent ID, name). IDs are stable across renames (as for most providers). */
private class FakeProvider {
    val docs = HashMap<String, Pair<String, String>>()
    var listings = 0
    fun children(parent: String): List<Pair<String, String>> {
        listings++
        return docs.filter { it.value.first == parent }.map { it.key to it.value.second }
    }
    fun query(id: String): Pair<String, String>? = if (id == "root") id to "Root" else docs[id]?.let { id to it.second }
}

class DocPathsTest {
    private val p = FakeProvider().apply {
        docs["1"] = "root" to "a"
        docs["2"] = "1" to "b"
    }
    private val paths = DocPaths<Pair<String, String>>(
        rootId = "root",
        children = p::children,
        query = p::query,
        idOf = { it.first },
        nameOf = { it.second },
    )

    @Test fun resolvesAndCaches() {
        assertEquals("2", paths.find(listOf("a", "b"))?.first)
        val before = p.listings
        assertEquals("2", paths.find(listOf("a", "b"))?.first)
        assertEquals(before, p.listings, "the second lookup comes from the cache")
        assertNull(paths.find(listOf("a", "zzz")))
    }

    @Test fun renamedFolderIsLookedUpAgain() {
        assertEquals("2", paths.find(listOf("a", "b"))?.first)
        // Renamed on the phone: the cached ID of "a" now names "c", and a new "a" appears.
        p.docs["1"] = "root" to "c"
        p.docs["3"] = "root" to "a"
        p.docs["4"] = "3" to "b"
        assertEquals("4", paths.find(listOf("a", "b"))?.first)
        assertEquals("2", paths.find(listOf("c", "b"))?.first)
    }

    @Test fun vanishedDocumentIsNotFound() {
        assertEquals("2", paths.find(listOf("a", "b"))?.first)
        p.docs.remove("2")
        assertNull(paths.find(listOf("a", "b")))
    }

    @Test fun staleIdThatThrowsIsLookedUpAgain() {
        val throwing = DocPaths<Pair<String, String>>(
            rootId = "root",
            children = p::children,
            query = { id -> if (id == "1") throw FileNotFoundException(id) else p.query(id) },
            idOf = { it.first },
            nameOf = { it.second },
        )
        throwing.remember("a", "1")
        assertEquals("2", throwing.find(listOf("a", "b"))?.first)
    }
}
