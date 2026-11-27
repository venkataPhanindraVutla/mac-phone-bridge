package io.github.anmirror.feature.clipboard

import io.github.anmirror.protocol.v1.TransferError
import io.github.anmirror.protocol.v1.TransferOffer
import io.github.anmirror.transfer.IncomingFile
import io.github.anmirror.transfer.IncomingSinks
import io.github.anmirror.transfer.SinkResult
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.security.DigestOutputStream
import java.security.MessageDigest
import java.util.UUID

/**
 * Where clipboard images from the Mac land (SPEC 14): a part file in [dir], renamed once whole,
 * then put on the clipboard by [bridge]. Only the newest image is kept; the ones before go. An
 * offer over [ClipboardBridge.MAX_IMAGE_BYTES] is refused `DENIED`. The caller checks the gate.
 */
class ClipImageInbox(private val dir: File, private val bridge: ClipboardBridge) : IncomingSinks {
    override fun open(offer: TransferOffer): SinkResult {
        if (offer.size > ClipboardBridge.MAX_IMAGE_BYTES) return SinkResult.Refused(TransferError.TRANSFER_ERROR_DENIED)
        if (!dir.isDirectory && !dir.mkdirs()) return SinkResult.Refused(TransferError.TRANSFER_ERROR_IO)
        val base = "clip-" + UUID.randomUUID()
        val part = File(dir, "$base.part")
        val digest = MessageDigest.getInstance("SHA-256")
        val stream = DigestOutputStream(FileOutputStream(part), digest)
        val final = File(dir, base + "." + extension(offer.name))
        return SinkResult.Ready(object : IncomingFile {
            override val output: OutputStream = stream

            override fun commit(): String {
                stream.close()
                if (!part.renameTo(final)) throw java.io.IOException("rename")
                dir.listFiles()?.forEach { if (it != final && !it.name.endsWith(".part")) it.delete() }
                bridge.acceptImageFromMac(final, digest.digest())
                return final.name
            }

            override fun abort() {
                runCatching { stream.close() }
                part.delete()
                final.delete()
            }
        })
    }

    /** The offer name's extension when it is a plain short one (the provider types the image by it), else png. */
    internal fun extension(name: String): String =
        name.substringAfterLast('.', "").lowercase().takeIf { it.length in 1..5 && it.all(Char::isLetterOrDigit) } ?: "png"
}
