package io.github.anmirror.phone

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.phone.platform.BlobCipher
import io.github.anmirror.phone.platform.BlobFile
import io.github.anmirror.phone.platform.EncryptedPairedMacStore
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.security.ProviderException
import javax.crypto.AEADBadTagException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EncryptedPairedMacStoreTest {
    private class MemFile(var blob: ByteArray? = null) : BlobFile {
        var backup: ByteArray? = null
        override fun read() = blob
        override fun write(blob: ByteArray) { this.blob = blob }
        override fun backUp() { backup = blob }
    }

    private class FakeCipher : BlobCipher {
        var failure: Exception? = null
        override fun encrypt(plain: ByteArray) = plain
        override fun decrypt(blob: ByteArray): ByteArray = failure?.let { throw it } ?: blob
    }

    private fun mac(id: String) = PairedMac(id, "n$id", "ab", byteArrayOf(1), null, null, 1L)

    @Test
    fun transientReadFailureLeavesFileUntouchedOnSaveAndRemove() = runBlocking<Unit> {
        val file = MemFile()
        val cipher = FakeCipher()
        val seen = mutableListOf<String>()
        val store = EncryptedPairedMacStore(file, cipher) { seen += it }
        store.save(mac("a"))
        val before = file.blob!!.copyOf()

        cipher.failure = ProviderException("keystore busy")
        assertFailsWith<IOException> { store.save(mac("b")) }
        assertContentEquals(before, file.blob)
        assertFailsWith<IOException> { store.remove("a") }
        assertContentEquals(before, file.blob)
        assertNull(file.backup)
        assertTrue(seen.all { it == "ProviderException" } && seen.isNotEmpty())

        cipher.failure = null
        store.save(mac("b"))
        assertEquals(listOf("a", "b"), store.all().map { it.id })
    }

    @Test
    fun permanentFailureKeepsBackupThenReplaces() = runBlocking<Unit> {
        val file = MemFile()
        val cipher = FakeCipher()
        val store = EncryptedPairedMacStore(file, cipher)
        store.save(mac("a"))
        val old = file.blob!!.copyOf()

        cipher.failure = AEADBadTagException()
        store.save(mac("b"))
        assertContentEquals(old, file.backup)
        cipher.failure = null
        assertEquals(listOf("b"), store.all().map { it.id })
    }

    @Test
    fun confirmedEmptyOnlyForAbsentOrEmpty() = runBlocking<Unit> {
        val file = MemFile()
        val cipher = FakeCipher()
        val store = EncryptedPairedMacStore(file, cipher)
        assertTrue(store.confirmedEmpty())
        store.save(mac("a"))
        assertFalse(store.confirmedEmpty())
        cipher.failure = ProviderException()
        assertFalse(store.confirmedEmpty())
        cipher.failure = null
        store.remove("a")
        assertTrue(store.confirmedEmpty())
        assertNotNull(file.blob)
    }
}
