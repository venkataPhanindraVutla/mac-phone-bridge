package io.github.anmirror.feature.mirror

import io.github.anmirror.protocol.v1.AudioCodec
import io.github.anmirror.protocol.v1.VideoCodec
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ServerCommandTest {
    @Test
    fun commandMatchesPinnedLine() {
        val o = HelperOptions(0x0a1b2c3d, 1920, 8_000_000, 60, VideoCodec.VIDEO_CODEC_H264, true, AudioCodec.AUDIO_CODEC_OPUS, true)
        assertEquals(
            "CLASSPATH=/data/local/tmp/anmirror-helper-0a1b2c3d.jar app_process / com.genymobile.scrcpy.Server 5.0.1-am1 " +
                "scid=0a1b2c3d log_level=warn tunnel_forward=true video=true audio=true control=true video_codec=h264 " +
                "audio_codec=opus max_size=1920 video_bit_rate=8000000 max_fps=60 clipboard_autosync=true cleanup=true " +
                "power_off_on_close=false",
            ServerCommand.build(o, "5.0.1-am1"),
        )
    }

    @Test
    fun commandCarriesH265AacAndOffSwitches() {
        val o = HelperOptions(1, 960, 2_000_000, 30, VideoCodec.VIDEO_CODEC_H265, false, AudioCodec.AUDIO_CODEC_AAC, false)
        val line = ServerCommand.build(o, "5.0.1-am1")
        assertTrue("scid=00000001 " in line)
        assertTrue(" audio=false " in line)
        assertTrue(" video_codec=h265 audio_codec=aac max_size=960 video_bit_rate=2000000 max_fps=30 clipboard_autosync=false " in line)
    }

    @Test
    fun unspecifiedCodecsMeanH264AndOpus() {
        val start = mirrorStart().toBuilder()
            .setVideoCodec(VideoCodec.VIDEO_CODEC_UNSPECIFIED)
            .setAudioCodec(AudioCodec.AUDIO_CODEC_UNSPECIFIED)
            .build()
        val line = ServerCommand.build(HelperOptions.from(start, 7, clipboardAutosync = false), "5.0.1-am1")
        assertTrue(" video_codec=h264 audio_codec=opus " in line)
    }

    @Test
    fun optionsComeFromTheStart() {
        val o = HelperOptions.from(mirrorStart(audio = false), 42, clipboardAutosync = true)
        assertEquals(HelperOptions(42, 1920, 8_000_000, 60, VideoCodec.VIDEO_CODEC_H264, false, AudioCodec.AUDIO_CODEC_OPUS, true), o)
    }

    @Test
    fun killStaleMatchesOnlyOurHelper() {
        val kill = ServerCommand.killStale("5.0.1-am1")
        assertEquals("pkill -f 'com.genymobile.scrcpy.[S]erver 5.0.1-am1'", kill)
        // pkill -f matches an extended regex against each process's whole command line.
        val pattern = Regex(kill.removePrefix("pkill -f '").removeSuffix("'"))
        val o = HelperOptions(0x0a1b2c3d, 1920, 8_000_000, 60, VideoCodec.VIDEO_CODEC_H264, true, AudioCodec.AUDIO_CODEC_OPUS, true)
        val helper = ServerCommand.build(o, "5.0.1-am1").substringAfter(' ') // what app_process's argv shows
        assertTrue(pattern.containsMatchIn(helper))
        // Not the helper's clean-up process (it turns the screen back on), not the shell running
        // this very pkill, and not a scrcpy a computer started.
        assertTrue(!pattern.containsMatchIn("app_process / com.genymobile.scrcpy.CleanUp 0 -1 false false -1 -1"))
        assertTrue(!pattern.containsMatchIn("sh -c $kill"))
        assertTrue(!pattern.containsMatchIn("app_process / com.genymobile.scrcpy.Server 3.3.1 scid=1234abcd"))
    }

    /** M3: each session pushes its own jar, so an earlier session's clean-up unlinks only that one. */
    @Test
    fun jarPathIsPerSession() {
        assertEquals("/data/local/tmp/anmirror-helper-0a1b2c3d.jar", ServerCommand.jarPath(0x0a1b2c3d))
        assertEquals("/data/local/tmp/anmirror-helper-00000001.jar", ServerCommand.jarPath(1))
        val o = HelperOptions(1, 960, 2_000_000, 30, VideoCodec.VIDEO_CODEC_H264, false, AudioCodec.AUDIO_CODEC_OPUS, false)
        assertTrue(ServerCommand.build(o, "5.0.1-am1").startsWith("CLASSPATH=/data/local/tmp/anmirror-helper-00000001.jar "))
    }

    /** Jars a session pushed but never launched (its clean-up unlinks a launched one at once), older than a minute. */
    @Test
    fun sweepRemovesOnlyOldLeftoverJars() {
        assertEquals(
            "find /data/local/tmp -maxdepth 1 -name 'anmirror-helper*.jar' -mmin +1 -delete",
            ServerCommand.sweepStaleJars(),
        )
    }

    @Test
    fun socketNameIsEightHexDigits() {
        assertEquals("scrcpy_0a1b2c3d", ServerCommand.socketName(0x0a1b2c3d))
        assertEquals("scrcpy_00000000", ServerCommand.socketName(0))
        assertEquals("scrcpy_7fffffff", ServerCommand.socketName(0x7FFFFFFF))
    }

    @Test
    fun scidIs31Bit() {
        val allOnes = object : Random() {
            override fun nextBits(bitCount: Int): Int = -1 ushr (32 - bitCount)
        }
        assertEquals(0x7FFFFFFF, ServerCommand.newScid(allOnes))
        val random = Random(1)
        repeat(1_000) { assertTrue(ServerCommand.newScid(random) in 0..0x7FFFFFFF) }
    }
}
