package io.github.anmirror.feature.mirror

import io.github.anmirror.adb.AdbClient
import io.github.anmirror.protocol.v1.HotspotFailure
import io.github.anmirror.protocol.v1.HotspotSecurity
import io.github.anmirror.protocol.v1.HotspotState
import kotlinx.coroutines.CancellationException
import java.io.IOException

/**
 * hotspot.v1 (SPEC 25), phone side: pushes the helper jar over the app's own ADB link, runs its
 * `Hotspot` entry point as the shell user, and turns the one line it prints into a
 * [HotspotState]. The jar is deleted afterwards. The passphrase is never logged.
 */
class HotspotRunner(
    private val adb: AdbClient,
    private val installer: HelperInstaller,
    private val scid: () -> Int = { ServerCommand.newScid() },
) {
    suspend fun run(on: Boolean): HotspotState {
        val path = ServerCommand.jarPath(scid())
        return try {
            installer.install(path) { true }
            parseHotspotLine(adb.shell(command(path, on)), on)
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            failed(HotspotFailure.HOTSPOT_FAILURE_FAILED)
        } finally {
            runCatching { adb.shell("rm -f $path") }
        }
    }

    companion object {
        const val ENTRY = "com.genymobile.scrcpy.anmirror.Hotspot"

        fun command(jar: String, on: Boolean) = "CLASSPATH=$jar app_process / $ENTRY ${if (on) "on" else "off"}"

        fun failed(f: HotspotFailure): HotspotState = HotspotState.newBuilder().setFailure(f).build()

        /** The helper's last `ok`, `off` or `fail` line; anything else is FAILED. */
        fun parseHotspotLine(output: String, on: Boolean): HotspotState {
            val line = output.lineSequence().map { it.trim() }.lastOrNull { it.startsWith("ok ") || it == "off" || it.startsWith("fail ") }
                ?: return failed(HotspotFailure.HOTSPOT_FAILURE_FAILED)
            val parts = line.split(' ')
            return when (parts[0]) {
                "off" -> if (on) failed(HotspotFailure.HOTSPOT_FAILURE_FAILED) else HotspotState.getDefaultInstance()
                "fail" -> failed(
                    if (parts.getOrNull(1) == "refused") HotspotFailure.HOTSPOT_FAILURE_REFUSED else HotspotFailure.HOTSPOT_FAILURE_FAILED,
                )
                else -> {
                    val ssid = unhex(parts.getOrNull(1)) ?: return failed(HotspotFailure.HOTSPOT_FAILURE_FAILED)
                    val pass = unhex(parts.getOrNull(2)) ?: return failed(HotspotFailure.HOTSPOT_FAILURE_FAILED)
                    val security = when (parts.getOrNull(3)) {
                        "wpa2" -> HotspotSecurity.HOTSPOT_SECURITY_WPA2
                        "wpa3" -> HotspotSecurity.HOTSPOT_SECURITY_WPA3
                        "wpa3_transition" -> HotspotSecurity.HOTSPOT_SECURITY_WPA3_TRANSITION
                        else -> HotspotSecurity.HOTSPOT_SECURITY_OPEN
                    }
                    if (ssid.isEmpty()) return failed(HotspotFailure.HOTSPOT_FAILURE_FAILED)
                    HotspotState.newBuilder().setOn(true).setSsid(ssid).setPassphrase(pass).setSecurity(security).build()
                }
            }
        }

        /** "-" is empty; anything not hex is null. */
        private fun unhex(s: String?): String? {
            if (s == null) return null
            if (s == "-") return ""
            if (s.length % 2 != 0 || !s.all { it in '0'..'9' || it in 'a'..'f' }) return null
            return String(ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }, Charsets.UTF_8)
        }
    }
}
