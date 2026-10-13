package com.focubili.app

import androidx.media3.common.PlaybackException
import org.junit.Assert.*
import org.junit.Test

class PlaybackCodecBoundaryTest {
    data class Track(val quality: Int, val codec: String, val supported: Boolean)
    private fun plan(vararg tracks: Track) = PlaybackTrackPolicy.playableTracks(
        tracks.toList(), 80, { it.quality }, { PlaybackTrackPolicy.compatibilityScore(it.codec) }, { it.supported },
    )

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
