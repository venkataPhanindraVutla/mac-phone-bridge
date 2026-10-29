package io.github.anmirror.feature.browse

import io.github.anmirror.protocol.v1.BrowseOutcome
import io.github.anmirror.protocol.v1.RootKind
import io.github.anmirror.transfer.IncomingFile
import io.github.anmirror.transfer.OutgoingFile
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class JavaFileTreeTest {
    @get:Rule val tmp = TemporaryFolder()

    private lateinit var rootDir: File
    private lateinit var outside: File
    private lateinit var secret: File

    private fun tree(fds: Descriptors = NioDescriptors): JavaFileTree {
        rootDir = tmp.newFolder("root")
        outside = tmp.newFolder("outside")
        secret = File(outside, "secret.txt").apply { writeText("secret") }
        return JavaFileTree(
            rootDir,
            RootInfo("all", "Phone storage", RootKind.ROOT_KIND_ALL_FILES, true),
            mimeFor = { name -> if (name.endsWith(".jpg")) "image/jpeg" else "application/octet-stream" },
            free = { null },
            fds = fds,
        )
    }

    /**
     * The JVM opener, with the descriptor's real path made up by the test: on Android that path
     * comes from /proc/self/fd, which this host (macOS) does not have.
     */
    private class ReportingDescriptors(
        var readPath: (File) -> String? = { null },
        var writePath: (File) -> String? = { null },
        val beforeRead: (File) -> Unit = {},
    ) : Descriptors {
        val closed = java.util.concurrent.atomic.AtomicInteger()
        override fun openRead(file: File): ReadHandle {
            beforeRead(file)
            val h = NioDescriptors.openRead(file)
            return ReadHandle(h.input, h.size, readPath(file)) { closed.incrementAndGet(); h.close() }
        }
        override fun createNew(file: File): WriteHandle {
            val h = NioDescriptors.createNew(file)
            return WriteHandle(h.output) { writePath(file) }
        }
    }

    private fun link(at: File, target: File) = Files.createSymbolicLink(at.toPath(), target.toPath())

    private fun <T> ok(r: TreeResult<T>): T = assertIs<TreeResult.Ok<T>>(r, "expected Ok, got $r").value

    private fun err(r: TreeResult<*>): BrowseOutcome = assertIs<TreeResult.Err>(r, "expected Err, got $r").outcome

    private fun names(dir: File) = dir.list().orEmpty().sorted()

    private fun IncomingFile.write(text: String) = output.write(text.toByteArray())

    private fun OutgoingFile.readText(): String = open().use { String(it.readBytes()) }

    @Test fun symlinkOutOfRootIsBadPath() {
        val t = tree()
        link(File(rootDir, "escape"), outside)
        link(File(rootDir, "secret-link.txt"), secret)
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.stat("escape")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.list("escape")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.stat("escape/secret.txt")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.openRead("escape/secret.txt")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.openRead("secret-link.txt")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.openWrite("escape", "x.txt", overwrite = false)))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.openWrite("", "secret-link.txt", overwrite = true)))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.mkdir("escape/new")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.rename("escape/secret.txt", "s.txt")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.delete("escape/secret.txt")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.stat("../outside/secret.txt")))
        assertEquals(listOf("secret.txt"), names(outside))
        assertEquals("secret", secret.readText())
        assertFalse(File(outside, "new").exists())
    }

    @Test fun symlinkOutOfRootIsNotListed() {
        val t = tree()
        File(rootDir, "docs").mkdir()
        File(rootDir, "a.jpg").writeText("abc")
        link(File(rootDir, "escape"), outside)
        link(File(rootDir, "secret-link.txt"), secret)
        link(File(rootDir, "dangling"), File(rootDir, "nothing-here"))
        link(File(rootDir, "inner"), File(rootDir, "docs"))
        // The engine's own in-progress file is never shown.
        File(rootDir, ".0f8fad5b-d9cb-469f-a165-70867728950e.part").writeText("partial")
        File(rootDir, ".hidden").writeText("h")

        val entries = ok(t.list("")).associateBy { it.name }
        assertEquals(setOf("docs", "a.jpg", "inner", ".hidden"), entries.keys)
        assertTrue(entries.getValue("docs").isDir)
        assertTrue(entries.getValue("inner").isDir)
        assertEquals(EntryInfo("a.jpg", false, 3, File(rootDir, "a.jpg").lastModified(), "image/jpeg"), entries["a.jpg"])
        assertEquals("", entries.getValue("docs").mime)
    }

    @Test fun deleteDoesNotFollowSymlinkOutOfRoot() {
        val t = tree()
        val dir = File(rootDir, "dir").apply { mkdir() }
        File(dir, "mine.txt").writeText("m")
        link(File(dir, "escape"), outside)
        link(File(dir, "secret-link.txt"), secret)
        File(rootDir, "docs").mkdir()
        File(rootDir, "docs/keep.txt").writeText("k")
        link(File(rootDir, "inner"), File(rootDir, "docs"))

        ok(t.delete("dir"))
        assertFalse(dir.exists())
        assertEquals(listOf("secret.txt"), names(outside))
        assertEquals("secret", secret.readText())

        // A link inside the root goes, its target stays.
        ok(t.delete("inner"))
        assertFalse(Files.exists(File(rootDir, "inner").toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS))
        assertEquals("k", File(rootDir, "docs/keep.txt").readText())

        // A link out of the root is not something the Mac can see.
        link(File(rootDir, "escape"), outside)
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.delete("escape")))
        assertEquals(listOf("secret.txt"), names(outside))
    }

    @Test fun deleteIsRecursive() {
        val t = tree()
        File(rootDir, "a/b/c").mkdirs()
        File(rootDir, "a/one.txt").writeText("1")
        File(rootDir, "a/b/c/two.txt").writeText("2")
        File(rootDir, "keep.txt").writeText("k")
        ok(t.delete("a"))
        assertEquals(listOf("keep.txt"), names(rootDir))
        ok(t.delete("keep.txt"))
        assertEquals(emptyList(), names(rootDir))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, err(t.delete("keep.txt")))
        // The root itself is never deleted.
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.delete("")))
        assertTrue(rootDir.isDirectory)
    }

    @Test fun mkdirExistingIsExists() {
        val t = tree()
        val made = ok(t.mkdir("photos"))
        assertEquals("photos", made.name)
        assertTrue(made.isDir)
        assertTrue(File(rootDir, "photos").isDirectory)
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_EXISTS, err(t.mkdir("photos")))
        File(rootDir, "file.txt").writeText("f")
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_EXISTS, err(t.mkdir("file.txt")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, err(t.mkdir("missing/inner")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.mkdir("")))
        ok(t.mkdir("photos/2026"))
        assertTrue(File(rootDir, "photos/2026").isDirectory)
    }

    @Test fun writeWithoutOverwriteGetsCounter() {
        val t = tree()
        File(rootDir, "photo.jpg").writeText("old")
        val sink = ok(t.openWrite("", "photo.jpg", overwrite = false))
        sink.write("new")
        assertEquals("photo (1).jpg", sink.commit())
        assertEquals("old", File(rootDir, "photo.jpg").readText())
        assertEquals("new", File(rootDir, "photo (1).jpg").readText())
        assertEquals(listOf("photo (1).jpg", "photo.jpg"), names(rootDir))

        // Collisions are case-insensitive (SPEC 16).
        val again = ok(t.openWrite("", "PHOTO.jpg", overwrite = false))
        again.write("third")
        assertEquals("PHOTO (2).jpg", again.commit())
    }

    @Test fun writeWithOverwriteReplacesOnCommit() {
        val t = tree()
        File(rootDir, "docs").mkdir()
        File(rootDir, "docs/report.txt").writeText("old")
        val sink = ok(t.openWrite("docs", "report.txt", overwrite = true))
        sink.write("new")
        // Until commit the old file is untouched, and the partial is hidden.
        assertEquals("old", File(rootDir, "docs/report.txt").readText())
        assertEquals(listOf("report.txt"), ok(t.list("docs")).map { it.name })
        assertEquals("report.txt", sink.commit())
        assertEquals("new", File(rootDir, "docs/report.txt").readText())
        assertEquals(listOf("report.txt"), names(File(rootDir, "docs")))
    }

    @Test fun abortedWriteLeavesNoPart() {
        val t = tree()
        File(rootDir, "keep.txt").writeText("k")
        val sink = ok(t.openWrite("", "new.bin", overwrite = false))
        sink.write("partial")
        assertEquals(2, names(rootDir).size, "the partial file exists while writing")
        sink.abort()
        assertEquals(listOf("keep.txt"), names(rootDir))
        assertFailsWith<IOException> { sink.output.write(1) } // the output was closed
    }

    @Test fun commitRefusesDirectorySwappedForSymlink() {
        val t = tree()
        val dir = File(rootDir, "up").apply { mkdir() }
        val sink = ok(t.openWrite("up", "x.txt", overwrite = false))
        sink.write("data")
        // The checked directory is replaced by a link out of the root before the rename.
        val moved = File(rootDir, "up-moved")
        assertTrue(dir.renameTo(moved))
        link(dir, outside)
        assertFailsWith<IOException> { sink.commit() }
        sink.abort() // the engine aborts after a commit that threw
        // Nothing was written or deleted through the link.
        assertEquals(listOf("secret.txt"), names(outside))
        assertEquals("secret", secret.readText())
        assertFalse(File(moved, "x.txt").exists())
        // Known leak on this JVM opener: the part moved with its folder, and the abort (by path)
        // can't find it. On Android the descriptor's /proc/self/fd path leads the abort to it
        // (abortDeletesThePartWhereItsDescriptorIs).
        assertEquals(1, names(moved).count { PART_NAME.matches(it) })
    }

    @Test fun abortDeletesThePartWhereItsDescriptorIs() {
        var movedTo: File? = null
        val fds = ReportingDescriptors(writePath = { f -> (movedTo?.let { File(it, f.name) } ?: f).path })
        val t = tree(fds)
        val dir = File(rootDir, "up").apply { mkdir() }
        val sink = ok(t.openWrite("up", "x.txt", overwrite = false))
        sink.write("data")
        val moved = File(rootDir, "up-moved")
        assertTrue(dir.renameTo(moved))
        movedTo = moved
        assertFailsWith<IOException> { sink.commit() } // the part is not where it was checked
        sink.abort()
        assertEquals(emptyList(), names(moved))
    }

    @Test fun readOfDescriptorOutsideRootIsBadPath() {
        // As if a folder on the way had been swapped for a link between the check and the open.
        val fds = ReportingDescriptors(readPath = { secret.path })
        val t = tree(fds)
        File(rootDir, "a.txt").writeText("a")
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.openRead("a.txt")))
        assertEquals(1, fds.closed.get(), "the descriptor is closed")
        fds.readPath = { f -> f.path }
        assertEquals("a", ok(t.openRead("a.txt")).readText())
    }

    @Test fun readSideSwapIsRefused() {
        // Between the check and the open the file becomes a link out of the root: O_NOFOLLOW refuses it.
        lateinit var target: File
        val fds = ReportingDescriptors(beforeRead = { f ->
            assertTrue(f.delete())
            link(f, target)
        })
        val t = tree(fds)
        target = secret
        File(rootDir, "a.txt").writeText("a")
        assertIs<TreeResult.Err>(t.openRead("a.txt"))
        assertEquals("secret", secret.readText())
    }

    @Test fun symlinkLoopIsNeitherListedNorFollowed() {
        val t = tree()
        link(File(rootDir, "a"), File(rootDir, "b"))
        link(File(rootDir, "b"), File(rootDir, "a"))
        File(rootDir, "keep.txt").writeText("k")
        assertEquals(listOf("keep.txt"), ok(t.list("")).map { it.name })
        assertIs<TreeResult.Err>(t.stat("a"))
        assertIs<TreeResult.Err>(t.list("a"))
        assertIs<TreeResult.Err>(t.openRead("a"))
        assertIs<TreeResult.Err>(t.openWrite("a", "x.txt", overwrite = false))
        assertIs<TreeResult.Err>(t.delete("a/b"))
        assertEquals(listOf("a", "b", "keep.txt"), names(rootDir))
    }

    @Test fun linkToTheRootsParentIsBadPath() {
        val t = tree()
        link(File(rootDir, "up"), rootDir.parentFile!!)
        assertEquals(emptyList(), ok(t.list("")).map { it.name })
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.list("up")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.openRead("up/outside/secret.txt")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.openWrite("up/outside", "x.txt", overwrite = false)))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.delete("up/outside")))
        assertEquals(listOf("secret.txt"), names(outside))
    }

    @Test fun failedCaseOnlyRenameMovesBack() {
        val dir = tmp.newFolder("r")
        val source = File(dir, "a.txt").apply { writeText("a") }.toPath()
        val temp = File(dir, ".t.part").toPath()
        var moves = 0
        assertFailsWith<IOException> {
            renameThrough(source, temp, File(dir, "A.txt").toPath()) { from, to ->
                if (++moves == 2) throw IOException("refused")
                Files.move(from, to)
            }
        }
        assertEquals(listOf("a.txt"), names(dir))
        assertEquals("a", source.toFile().readText())
    }

    @Test fun partNamesAreHiddenInAnyCase() {
        val t = tree()
        File(rootDir, ".0F8FAD5B-D9CB-469F-A165-70867728950E.PART").writeText("p")
        File(rootDir, "a.txt").writeText("a")
        assertEquals(listOf("a.txt"), ok(t.list("")).map { it.name })
    }

    @Test fun renameRenamesInPlace() {
        val t = tree()
        File(rootDir, "docs").mkdir()
        File(rootDir, "docs/a.txt").writeText("a")
        File(rootDir, "docs/b.txt").writeText("b")
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_EXISTS, err(t.rename("docs/a.txt", "b.txt")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.rename("docs/a.txt", "../a.txt")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.rename("", "x")))
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, err(t.rename("docs/zzz.txt", "y.txt")))
        val renamed = ok(t.rename("docs/a.txt", "c.txt"))
        assertEquals("c.txt", renamed.name)
        assertEquals(listOf("b.txt", "c.txt"), names(File(rootDir, "docs")))
    }

    @Test fun readOpensTheFileAndCloses() {
        val t = tree()
        File(rootDir, "a.jpg").writeText("hello")
        val file = ok(t.openRead("a.jpg"))
        assertEquals("a.jpg", file.name)
        assertEquals(5, file.size)
        assertEquals("image/jpeg", file.mime)
        assertEquals("hello", file.readText())
        assertIs<Closeable>(file).close()
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_NOT_FOUND, err(t.openRead("missing.jpg")))
        File(rootDir, "dir").mkdir()
        assertEquals(BrowseOutcome.BROWSE_OUTCOME_BAD_PATH, err(t.openRead("dir")))
    }
}
