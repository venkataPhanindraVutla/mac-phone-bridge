package io.github.anmirror.feature.mirror

/**
 * The extra Developer options switch some makers need before ADB may inject taps and text
 * (Full mode's control). The phone can't read it, so the Full mode screen just names it.
 */
enum class MakerGuidance {
    NONE,

    /** Xiaomi, Redmi, POCO: "USB debugging (Security settings)". */
    USB_DEBUGGING_SECURITY,

    /** OPPO, OnePlus, realme, vivo, iQOO: "Disable permission monitoring". */
    DISABLE_PERMISSION_MONITORING,
    ;

    companion object {
        private val XIAOMI = setOf("xiaomi", "redmi", "poco")
        private val BBK = setOf("oppo", "oneplus", "realme", "vivo", "iqoo")

        /** From `Build.MANUFACTURER`, case-insensitively. */
        fun of(manufacturer: String): MakerGuidance = when (manufacturer.trim().lowercase()) {
            in XIAOMI -> USB_DEBUGGING_SECURITY
            in BBK -> DISABLE_PERMISSION_MONITORING
            else -> NONE
        }
    }
}
