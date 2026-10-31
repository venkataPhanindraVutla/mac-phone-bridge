package io.github.anmirror.feature.mirror

import io.github.anmirror.protocol.v1.AudioCodec
import io.github.anmirror.protocol.v1.MirrorStart
import io.github.anmirror.protocol.v1.VideoCodec
import java.security.SecureRandom
import kotlin.random.Random
import kotlin.random.asKotlinRandom

/** The helper's options for one session (SPEC 24: the start's options under the helper's own names). */
data class HelperOptions(
    val scid: Int,
    val maxSize: Int,
    val videoBitRate: Int,
    val maxFps: Int,
    val videoCodec: VideoCodec,
    val audio: Boolean,
    val audioCodec: AudioCodec,
    val clipboardAutosync: Boolean,
) {
    companion object {
        fun from(start: MirrorStart, scid: Int, clipboardAutosync: Boolean): HelperOptions = HelperOptions(
            scid = scid,
            maxSize = start.maxSize,
            videoBitRate = start.videoBitRate,
            maxFps = start.maxFps,
            videoCodec = start.videoCodec,
            audio = start.audio,
            audioCodec = start.audioCodec,
            clipboardAutosync = clipboardAutosync,
        )
    }
}

/**
 * The helper's launch line (Global Constraints, exactly) and its socket name. The line is built
 * only from numbers and fixed words, so nothing from the Mac can reach the shell as text.
 */
object ServerCommand {
    private const val JAR_DIR = "/data/local/tmp"
    private const val SERVER_CLASS = "com.genymobile.scrcpy.Server"

    /**
     * The session's own copy of the helper jar (review M3). The helper's clean-up process unlinks
     * the jar in its CLASSPATH as soon as it has started, so with one shared path an earlier
     * session's clean-up could delete the jar the next session had just pushed.
     */
    fun jarPath(scid: Int): String = "$JAR_DIR/anmirror-helper-${hex(scid)}.jar"

    /**
     * Removes jars a session pushed but never launched (a launched one is unlinked by its clean-up
     * at once), and the shared jar of earlier builds: only those older than a minute, so no jar a
     * starting helper or clean-up still needs.
     */
    fun sweepStaleJars(): String = "find $JAR_DIR -maxdepth 1 -name 'anmirror-helper*.jar' -mmin +1 -delete"

    /**
     * Kills our helper of this [version] (ruling R53): its own command line is
     * `app_process / com.genymobile.scrcpy.Server <version> …` (the jar is only in CLASSPATH, an
     * environment variable). `[S]` keeps the pattern from matching the shell that runs it; the
     * helper's clean-up process (`…scrcpy.CleanUp`, which turns the screen back on) and a scrcpy a
     * computer started (another version) don't match either.
     */
    fun killStale(version: String): String = "pkill -f '" + SERVER_CLASS.replace(".Server", ".[S]erver") + " " + version + "'"

    fun build(o: HelperOptions, version: String): String = buildString {
        append("CLASSPATH=").append(jarPath(o.scid))
        append(" app_process / ").append(SERVER_CLASS).append(' ').append(version)
        append(" scid=").append(hex(o.scid))
        append(" log_level=warn tunnel_forward=true video=true")
        append(" audio=").append(o.audio)
        append(" control=true")
        append(" video_codec=").append(videoCodecName(o.videoCodec))
        append(" audio_codec=").append(audioCodecName(o.audioCodec))
        append(" max_size=").append(Integer.toUnsignedString(o.maxSize))
        append(" video_bit_rate=").append(Integer.toUnsignedString(o.videoBitRate))
        append(" max_fps=").append(Integer.toUnsignedString(o.maxFps))
        append(" clipboard_autosync=").append(o.clipboardAutosync)
        append(" cleanup=true power_off_on_close=false")
    }

    /** `scrcpy_<8 lowercase hex>`, under `localabstract:`. */
    fun socketName(scid: Int): String = "scrcpy_" + hex(scid)

    /** A random 31-bit session ID. */
    fun newScid(random: Random = SecureRandom().asKotlinRandom()): Int = random.nextInt() and 0x7FFFFFFF

    private fun hex(scid: Int) = "%08x".format(scid)

    /** An unspecified codec means H.264 (as the Mac sends it). */
    private fun videoCodecName(c: VideoCodec) = if (c == VideoCodec.VIDEO_CODEC_H265) "h265" else "h264"

    /** An unspecified codec means Opus. */
    private fun audioCodecName(c: AudioCodec) = if (c == AudioCodec.AUDIO_CODEC_AAC) "aac" else "opus"
}
