package io.github.anmirror.phone

/** Phone makers whose own battery manager stops background apps beyond what Android's exemption covers. */
enum class Maker { VIVO, XIAOMI, OPPO, SAMSUNG, HUAWEI }

/** Which maker's extra setting to point at, from `Build.MANUFACTURER`; sub-brands share their parent's settings. */
object MakerGuidance {
    private val byManufacturer = mapOf(
        "vivo" to Maker.VIVO, "iqoo" to Maker.VIVO,
        "xiaomi" to Maker.XIAOMI, "redmi" to Maker.XIAOMI, "poco" to Maker.XIAOMI,
        "oppo" to Maker.OPPO, "oneplus" to Maker.OPPO, "realme" to Maker.OPPO,
        "samsung" to Maker.SAMSUNG,
        "huawei" to Maker.HUAWEI, "honor" to Maker.HUAWEI,
    )

    /** Null for makers with no extra step known (Pixel, Fairphone, ...). */
    fun makerOf(manufacturer: String): Maker? = byManufacturer[manufacturer.trim().lowercase()]
}

/**
 * What the keep-connected screen and home row need. [exempt] is Android's battery-optimisation
 * exemption; [makerStepDone] is the user saying they did the maker's own step, which the phone
 * cannot read back.
 */
data class BackgroundState(val exempt: Boolean, val maker: Maker?, val makerStepDone: Boolean) {
    /** The screen and the home row are shown while either step is left. */
    val showsPrompt: Boolean get() = !exempt || (maker != null && !makerStepDone)

    /** What the Mac is told (`StatusUpdate.background_restricted`): the only fact the phone can read. */
    val restricted: Boolean get() = !exempt
}
