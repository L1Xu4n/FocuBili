package com.focubili.app

import androidx.media3.common.PlaybackException
import org.junit.Assert.*
import org.junit.Test

class PlaybackCodecBoundaryTest {
    data class Track(val quality: Int, val codec: String, val supported: Boolean)
    /** 生成默认兼容模式的有序候选。 */
    private fun plan(vararg tracks: Track) = PlaybackTrackPolicy.playableTracks(
        tracks.toList(), 80, { it.quality }, { PlaybackTrackPolicy.compatibilityScore(it.codec) }, { it.supported },
    )

    private data class SavingTrack(
        val quality: Int,
        val codec: String,
        val bandwidth: Long,
        val hardware: Boolean,
        val supported: Boolean = true,
    )

    /** 同档先选硬解和低码率再去重，兼容模式保留 AVC 首选和原码率顺序。 */
    @Test
    fun lowBitrateHardwareWinsBeforeDeduplicationAndKeepsAvcFallback() {
        val avc = SavingTrack(80, "avc1", 800_000, false)
        val highHevc = SavingTrack(80, "hvc1", 900_000, true)
        val lowHevc = highHevc.copy(bandwidth = 500_000)
        val knownAv1 = SavingTrack(80, "av01", 550_000, true)
        val unknownAv1 = knownAv1.copy(bandwidth = 0)
        val unsupported = SavingTrack(80, "av01.unsupported", 1, true, supported = false)
        val lowQualityAvc = avc.copy(quality = 64, bandwidth = 10)
        val items = listOf(avc, highHevc, unknownAv1, lowHevc, knownAv1, unsupported, lowQualityAvc, avc.copy(quality = 120))
        // 两种模式使用与控制器相同的排序和去重入口。
        fun ranked(dataSaver: Boolean) = PlaybackTrackPolicy.videoTracks(
            items, 80, dataSaver, { it.quality }, { it.codec }, { it.bandwidth },
            { PlaybackTrackPolicy.compatibilityScore(it.codec) + it.bandwidth },
            { it.supported }, { it.hardware },
        )
        assertEquals(listOf(lowHevc, knownAv1, avc, lowQualityAvc), ranked(true))
        assertEquals(listOf(avc, highHevc, knownAv1, lowQualityAvc), ranked(false))
    }

    /** API 29 起采用系统硬解标记，旧版排除软件属性和常见软件前缀。 */
    @Test
    fun decoderHardwareClassificationHonorsPlatformBoundary() {
        assertTrue(PlaybackTrackPolicy.isHardwareDecoder(29, "vendor.av1.decoder", true, false))
        assertFalse(PlaybackTrackPolicy.isHardwareDecoder(29, "vendor.av1.decoder", false, false))
        assertTrue(PlaybackTrackPolicy.isHardwareDecoder(28, "OMX.vendor.avc", false, false))
        assertFalse(PlaybackTrackPolicy.isHardwareDecoder(28, "OMX.vendor.avc", true, true))
        for (name in listOf("OMX.google.avc", "c2.android.av1", "c2.ffmpeg.hevc")) {
            assertFalse(PlaybackTrackPolicy.isHardwareDecoder(28, name, true, false))
        }
    }

    @Test fun unsupportedHdCannotOverrideSupportedLowAvc() {
        val tracks = plan(Track(80, "hvc1", false), Track(16, "avc1", true))
        assertEquals(listOf(16), tracks.map { it.quality })
    }

    @Test fun supportedHdWinsAndFallbackOrderIsFiniteAndNeverUpgrades() {
        val tracks = plan(Track(80, "hvc1", true), Track(80, "avc1", true), Track(64, "avc1", true), Track(120, "avc1", true))
        assertEquals(listOf("avc1", "hvc1", "avc1"), tracks.map { it.codec })
        assertEquals(listOf(80, 80, 64), tracks.map { it.quality })
        assertTrue(tracks.drop(tracks.size).isEmpty())
        assertTrue(plan(Track(80, "hvc1", false)).isEmpty())
    }

    @Test fun frameRatesRespectFractionsAndInvalidMetadata() {
        assertEquals(29.97003f, PlaybackTrackPolicy.frameRate("30000/1001")!!, 0.001f)
        assertEquals(60f, PlaybackTrackPolicy.frameRate("60")!!, 0.001f)
        for (value in listOf("", "0", "NaN", "60/0", "-1", "1/2/3")) assertNull(PlaybackTrackPolicy.frameRate(value))
    }

    @Test fun onlyDecoderErrorsUseCodecFallback() {
        assertTrue(PlaybackTrackPolicy.isDecoderFailure(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED))
        assertTrue(PlaybackTrackPolicy.isDecoderFailure(PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED))
        assertFalse(PlaybackTrackPolicy.isDecoderFailure(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS))
        assertFalse(PlaybackTrackPolicy.isDecoderFailure(PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED))
    }
}
