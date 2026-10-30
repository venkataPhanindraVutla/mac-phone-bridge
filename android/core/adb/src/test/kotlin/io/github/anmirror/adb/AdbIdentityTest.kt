package io.github.anmirror.adb

import java.security.interfaces.RSAPublicKey
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class AdbIdentityTest {
    private val now = 1_790_000_000_000L

    @Test
    fun identityRoundTrips() {
        val made = AdbIdentity.generate(nowMs = now)
        val back = AdbIdentity.decode(made.encodedKey(), made.encodedCertificate())
        assertContentEquals(made.encodedKey(), back.encodedKey())
        assertContentEquals(made.encodedCertificate(), back.encodedCertificate())
        assertEquals(made.certificate, back.certificate)
    }

    @Test
    fun certificateIsSelfSignedRsa2048() {
        val cert = AdbIdentity.generate(nowMs = now).certificate
        cert.verify(cert.publicKey) // throws unless signed by its own key
        assertEquals(cert.subjectX500Principal, cert.issuerX500Principal)
        assertEquals("CN=Android Mirroring", cert.subjectX500Principal.name)
        assertEquals(2048, (cert.publicKey as RSAPublicKey).modulus.bitLength())
        assertEquals("SHA512withRSA", cert.sigAlgName)
        assertEquals(Instant.ofEpochMilli(now).epochSecond, cert.notBefore.toInstant().epochSecond)
        val tenYears = Instant.ofEpochMilli(now).atZone(ZoneOffset.UTC).plusYears(10).toInstant()
        assertEquals(tenYears.epochSecond, cert.notAfter.toInstant().epochSecond)
    }
}
