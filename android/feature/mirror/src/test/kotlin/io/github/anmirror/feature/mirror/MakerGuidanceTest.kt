package io.github.anmirror.feature.mirror

import kotlin.test.Test
import kotlin.test.assertEquals

class MakerGuidanceTest {
    @Test
    fun xiaomiFamilyNeedsSecuritySetting() {
        for (m in listOf("Xiaomi", "xiaomi", "Redmi", "POCO")) {
            assertEquals(MakerGuidance.USB_DEBUGGING_SECURITY, MakerGuidance.of(m), m)
        }
    }

    @Test
    fun bbkFamilyNeedsPermissionMonitoring() {
        for (m in listOf("OPPO", "OnePlus", "realme", "vivo", "iQOO")) {
            assertEquals(MakerGuidance.DISABLE_PERMISSION_MONITORING, MakerGuidance.of(m), m)
        }
    }

    @Test
    fun othersNeedNothing() {
        for (m in listOf("Google", "samsung", "motorola", "")) {
            assertEquals(MakerGuidance.NONE, MakerGuidance.of(m), m)
        }
    }
}
