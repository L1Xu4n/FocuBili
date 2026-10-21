package com.focubili.app

import java.io.IOException
import java.net.SocketTimeoutException
import org.junit.Assert.*
import org.junit.Test

class MediaRuntimeDiagnosticsTest {
    @Test fun seekThatStaysReadyDoesNotMislabelALaterNetworkRebuffer() {
        val log = MediaRuntimeDiagnostics { 0L }
        log.begin(false); log.prepare(); log.sample(0, 1000, true, 1f); log.state("ready")
        log.seek(); log.seekReturned(ready = true)
        log.state("buffering"); log.state("ready")
        assertEquals("rebuffer", log.snapshot().single { it["event"] == "buffer_end" }["buffer_reason"])
        assertEquals(1L, log.snapshot().last()["rebuffer_count"])
    }
    @Test fun userPauseDuringRebufferDoesNotCountAsWaitingToPlay() {
        var now = 0L
        val log = MediaRuntimeDiagnostics { now }
        log.begin(false); log.prepare(); log.sample(0, 0, true, 1f); log.state("ready")
        log.state("buffering")
        now = 100; log.sample(0, 0, false, 1f)
        now = 1000; log.sample(0, 0, true, 1f)
        now = 1200; log.state("ready")
        assertEquals(300L, log.snapshot().last()["rebuffer_ms"])
        assertEquals(1200L, log.snapshot().single { it["event"] == "buffer_end" }["duration_ms"])
    }
    @Test fun initialSeekAndRealRebufferAreDistinctAndTimed() {
        var now = 0L
        val log = MediaRuntimeDiagnostics { now }
        log.begin(false); val token = log.prepare()
        log.sample(0, 0, true, 1f); log.state("buffering")
        now = 100; log.state("ready"); log.firstFrame(token)
        log.seek(); log.state("buffering"); now = 200; log.state("ready")
        log.state("buffering"); now = 500
        assertEquals(300L, log.snapshot().last()["rebuffer_ms"])
        log.state("ready")
        assertEquals(1L, log.snapshot().last()["rebuffer_count"])
        assertEquals(listOf("initial", "seek", "rebuffer"), log.snapshot().filter { it["event"] == "buffer_end" }.map { it["buffer_reason"] })
        val frame = log.snapshot().single { it["event"] == "first_frame" }
        assertEquals(100L, frame["first_frame_ms"])
    }

    @Test fun sourceAttemptsRejectStaleAudioVideoAndDecoderCallbacks() {
        val log = MediaRuntimeDiagnostics { 0L }
        log.begin(false); val old = log.prepare(); val current = log.prepare()
        log.recordFor(old, "load_error", mapOf("track" to "video"))
        log.firstFrame(old); log.dropped(old, 900)
        log.recordFor(current, "load_error", mapOf("track" to "audio", "cause" to "timeout"))
        log.recordFor(current, "load_end", mapOf("track" to "video", "bytes" to 1234))
        assertEquals(listOf("audio", "video"), log.snapshot().filter { it.containsKey("track") }.map { it["track"] })
        assertEquals(0L, log.snapshot().last()["dropped_frames"])
        log.begin(false)
        log.firstFrame(current)
        assertTrue(log.snapshot().none { it["event"] == "first_frame" })
    }

    @Test fun noHeartbeatEventsBoundedExportAndFirstFrameOnlyOnce() {
        val log = MediaRuntimeDiagnostics { 0L }
        log.begin(false); val token = log.prepare()
        val before = log.snapshot().size
        repeat(10000) { log.sample(it.toLong(), 1000, true, 1f); log.dropped(token, 1) }
        assertEquals(before, log.snapshot().size)
        log.firstFrame(token); log.firstFrame(token)
        assertEquals(1, log.snapshot().count { it["event"] == "first_frame" })
        repeat(10000) { log.recordFor(token, "load_error", mapOf("track" to "audio")) }
        assertEquals(64, log.snapshot().size)
        log.finish("released")
        val released = log.snapshot()
        log.recordFor(token, "load_end")
        assertEquals(released, log.snapshot())
    }

    @Test fun privacyAllowlistRejectsArbitraryStringsNonfiniteNumbersAndCredentials() {
        val safe = MediaRuntimeDiagnostics.safeFields(mapOf(
            "Cookie" to "SESSDATA=secret", "url" to "https://cdn.invalid/v?sign=secret",
            "subtitle" to "private text", "decoder" to "OMX.secret?Cookie=secret",
            "codec" to "avc1.secret&token=secret", "cause" to "secret", "fps" to Float.NaN,
            "bytes" to -1L, "duration_ms" to Double.POSITIVE_INFINITY, "quality" to 64,
        ))
        assertEquals(mapOf("quality" to 64L), safe)
        assertEquals(mapOf("cause" to "timeout"), MediaRuntimeAnalytics.failureFields(IOException("Cookie=secret", SocketTimeoutException("https://private"))))
    }

    @Test fun clearRemovesHistoryAndLaterEventsStillWork() {
        val log = MediaRuntimeDiagnostics { 0L }
        log.begin(false); val token = log.prepare(); log.firstFrame(token)
        log.clear(); assertTrue(log.snapshot().isEmpty())
        log.recordFor(token, "load_error", mapOf("track" to "audio"))
        assertEquals("load_error", log.snapshot().first()["event"])
        assertTrue(log.snapshot().none { it["event"] == "first_frame" })
    }

    @Test fun decoderAndFirstFrameSurviveRingPressureAndPlayerRelease() {
        var now = 0L
        val log = MediaRuntimeDiagnostics { now }
        log.begin(false); val token = log.prepare()
        now = 500; log.firstFrame(token)
        log.recordFor(token, "decoder", mapOf("track" to "video", "decoder" to "OMX.hisi.video.decoder.avc"))
        log.recordFor(token, "format", mapOf("track" to "video", "codec" to "avc1.64001F"))
        repeat(100) { log.recordFor(token, "load_error", mapOf("track" to "audio")) }
        log.finish("released")
        assertEquals(64, log.snapshot().size)
        assertEquals(500L, log.snapshot().last()["first_frame_ms"])
        assertEquals("OMX.hisi.video.decoder.avc", log.snapshot().single { it["event"] == "track_summary" }["decoder"])
    }
}
