package io.github.anmirror.phone

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MakerGuidanceTest {
    @Test
    fun vivoAndIqooMapToVivo() {
        for (m in listOf("vivo", "iQOO")) assertEquals(Maker.VIVO, MakerGuidance.makerOf(m), m)
    }

    @Test
    fun xiaomiFamily() {
        for (m in listOf("Xiaomi", "Redmi", "POCO")) assertEquals(Maker.XIAOMI, MakerGuidance.makerOf(m), m)
    }

    @Test
    fun oppoFamily() {
        for (m in listOf("OPPO", "OnePlus", "realme")) assertEquals(Maker.OPPO, MakerGuidance.makerOf(m), m)
    }

    @Test
    fun samsung() = assertEquals(Maker.SAMSUNG, MakerGuidance.makerOf("samsung"))

    @Test
    fun huaweiAndHonor() {
        for (m in listOf("HUAWEI", "HONOR")) assertEquals(Maker.HUAWEI, MakerGuidance.makerOf(m), m)
    }

    @Test
    fun unknownMakersHaveNoGuidance() {
        for (m in listOf("Google", "Fairphone", "")) assertNull(MakerGuidance.makerOf(m), m)
    }
}
