package io.github.anmirror.phone

import io.github.anmirror.connection.PairedMac
import io.github.anmirror.phone.platform.PairedMacsBlob
import io.github.anmirror.phone.platform.StoreRead
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.security.ProviderException
import javax.crypto.AEADBadTagException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class PairedMacsBlobTest {
    private val mac = PairedMac("id1", "n", "ab", byteArrayOf(1, 2, 3), null, null, 5L)

    @Test
    fun absentFileIsConfirmedEmpty() {
        assertEquals(StoreRead.Macs(emptyList()), PairedMacsBlob.decode(null) { it })
    }

    @Test
    fun goodBlobReadsMacs() {
        val blob = Json.encodeToString(ListSerializer(PairedMac.serializer()), listOf(mac)).encodeToByteArray()
        assertEquals(StoreRead.Macs(listOf(mac)), PairedMacsBlob.decode(blob) { it })
    }

    @Test
    fun providerExceptionIsUnreadable() {
        assertEquals(StoreRead.Unreadable("ProviderException"), PairedMacsBlob.decode(byteArrayOf(1)) { throw ProviderException("x") })
    }

    @Test
    fun generalSecurityExceptionIsUnreadable() {
        assertEquals(StoreRead.Unreadable("AEADBadTagException"), PairedMacsBlob.decode(byteArrayOf(1)) { throw AEADBadTagException() })
    }

    @Test
    fun badJsonIsUnreadable() {
        val r = PairedMacsBlob.decode(byteArrayOf(1)) { "{".encodeToByteArray() }
        assertIs<StoreRead.Unreadable>(r)
        assertEquals("JsonDecodingException", r.causeClass) // a SerializationException subclass
    }
}
