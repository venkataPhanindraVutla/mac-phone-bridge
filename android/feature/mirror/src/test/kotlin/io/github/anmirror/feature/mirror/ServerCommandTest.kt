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
            "CLASSPATH=/data/local/tmp/anmirror-helper.jar app_process / com.genymobile.scrcpy.Server 5.0.1-am1 " +
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
