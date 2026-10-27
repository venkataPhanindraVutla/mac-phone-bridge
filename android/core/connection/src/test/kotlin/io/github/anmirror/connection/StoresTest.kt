package io.github.anmirror.connection

import kotlinx.coroutines.runBlocking
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class StoresTest {
    private val mac = PairedMac("aa", "Ada’s Mac", "aa", ByteArray(32) { it.toByte() }, "10.0.0.5", 49152, 42)

    @Test
    fun jsonFileStoreRoundTripsAndPersists(): Unit = runBlocking {
        val dir = Files.createTempDirectory("store").toFile()
        val file = dir.resolve("paired-macs.json")
        val store = JsonFilePairedMacStore(file)
        assertEquals(emptyList(), store.all())
        store.save(mac)
        store.save(mac.copy(lastPort = 50000)) // same id: replaced, not appended
        store.save(mac.copy(id = "bb", fingerprintHex = "bb", lastHost = null, lastPort = null))

        val reread = JsonFilePairedMacStore(file).all()
        assertEquals(listOf("aa", "bb"), reread.map { it.id })
        assertEquals(50000, reread[0].lastPort)
        assertContentEquals(mac.discoveryKey, reread[0].discoveryKey)
        assertEquals(mac.copy(lastPort = 50000), reread[0])
        assertEquals(null, reread[1].lastHost)

        store.remove("aa")
        assertEquals(listOf("bb"), JsonFilePairedMacStore(file).all().map { it.id })
        dir.deleteRecursively()
    }

    @Test
    fun inMemoryStore(): Unit = runBlocking {
        val store = InMemoryPairedMacStore()
        store.save(mac)
        assertEquals(listOf(mac), store.all())
        store.remove(mac.id)
        assertEquals(emptyList(), store.all())
    }
}
