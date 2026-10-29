package io.github.anmirror.feature.browse

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.Closeable
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.channels.Channels
import java.nio.file.AccessDeniedException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.StandardOpenOption

/** An opened file to read. [realPath] is where the descriptor really points, when the system can tell. */
class ReadHandle(val input: InputStream, val size: Long, val realPath: String?, private val release: Closeable) : Closeable {
    override fun close() = release.close()
}

/** A new file being written. [realPath] is where its descriptor points now (it follows moves), or null. */
class WriteHandle(val output: OutputStream, val realPath: () -> String?)

/** The last component was a link, refused by `O_NOFOLLOW`. */
internal class LinkRefused : IOException()

/**
 * How [JavaFileTree] opens files: never through a link at the last component, and (where the
 * system can tell) reporting the path the opened descriptor really refers to, so a swap of a
 * folder on the way between the check and the open is caught after the open.
 */
interface Descriptors {
    fun openRead(file: File): ReadHandle

    /** Creates [file]; it must not exist (`O_EXCL`, so never through a link). */
    fun createNew(file: File): WriteHandle

    companion object {
        /** On Android, [ProcFdDescriptors]; elsewhere (the JVM test host) [NioDescriptors]. */
        fun platform(): Descriptors =
            if (System.getProperty("java.vm.name") == "Dalvik" && File("/proc/self/fd").isDirectory) ProcFdDescriptors else NioDescriptors
    }
}

/**
 * Android: `open(2)` with `O_NOFOLLOW | O_CLOEXEC` (and `O_CREAT | O_EXCL` for new files); the real
 * path is `readlink("/proc/self/fd/N")`. Runs on devices only; the JVM tests use [NioDescriptors]
 * with a stand-in for the real path.
 */
internal object ProcFdDescriptors : Descriptors {
    override fun openRead(file: File): ReadHandle {
        val pfd = open(file, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC)
        return ReadHandle(ParcelFileDescriptor.AutoCloseInputStream(pfd), pfd.statSize, realPath(pfd), pfd)
    }

    override fun createNew(file: File): WriteHandle {
        val flags = OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC
        val pfd = open(file, flags)
        return WriteHandle(ParcelFileDescriptor.AutoCloseOutputStream(pfd)) { realPath(pfd) }
    }

    private fun open(file: File, flags: Int): ParcelFileDescriptor {
        val fd: FileDescriptor = try {
            Os.open(file.path, flags, MODE)
        } catch (e: ErrnoException) {
            throw when (e.errno) {
                OsConstants.ELOOP -> LinkRefused()
                OsConstants.ENOENT, OsConstants.ENOTDIR -> NoSuchFileException(null)
                OsConstants.EACCES, OsConstants.EPERM -> AccessDeniedException(null)
                OsConstants.EEXIST -> FileAlreadyExistsException(null)
                else -> IOException("open failed: errno ${e.errno}")
            }
        }
        // A ParcelFileDescriptor gives the descriptor's number (for /proc) and closing streams.
        return try {
            ParcelFileDescriptor.dup(fd)
        } finally {
            try {
                Os.close(fd)
            } catch (e: ErrnoException) {
                // The dup holds the file.
            }
        }
    }

    /** Null once the descriptor is closed, or when /proc can't say. */
    private fun realPath(pfd: ParcelFileDescriptor): String? = try {
        Os.readlink("/proc/self/fd/${pfd.fd}")
    } catch (e: ErrnoException) {
        null
    } catch (e: IllegalStateException) {
        null
    }

    private const val MODE = 384 // 0600: shared storage ignores it
}

/** The JVM: NIO with `NOFOLLOW_LINKS` and `CREATE_NEW`; it can't tell where a descriptor points. */
internal object NioDescriptors : Descriptors {
    override fun openRead(file: File): ReadHandle {
        val channel = Files.newByteChannel(file.toPath(), StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)
        return ReadHandle(Channels.newInputStream(channel), channel.size(), null, channel)
    }

    override fun createNew(file: File): WriteHandle {
        val out = Files.newOutputStream(file.toPath(), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)
        return WriteHandle(out) { null }
    }
}
