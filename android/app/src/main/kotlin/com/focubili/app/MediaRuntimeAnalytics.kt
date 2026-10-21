package com.focubili.app

import android.os.Handler
import androidx.media3.common.Format
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MediaSourceEventListener
import java.io.IOException
import java.net.SocketTimeoutException

/** Only copies allowlisted scalar measurements from Media3. All callbacks use the player looper. */
@UnstableApi
internal class MediaRuntimeAnalytics(private val diagnostics: MediaRuntimeDiagnostics) : AnalyticsListener {
    private fun attempt(time: AnalyticsListener.EventTime): MediaRuntimeDiagnostics.Attempt? {
        if (time.timeline.isEmpty || time.windowIndex !in 0 until time.timeline.windowCount) return null
        return time.timeline.getWindow(time.windowIndex, Timeline.Window()).mediaItem
            .localConfiguration?.tag as? MediaRuntimeDiagnostics.Attempt
    }

    override fun onRenderedFirstFrame(time: AnalyticsListener.EventTime, output: Any, renderTimeMs: Long) {
        attempt(time)?.let(diagnostics::firstFrame)
    }

    override fun onVideoDecoderInitialized(time: AnalyticsListener.EventTime, name: String, timestampMs: Long, durationMs: Long) {
        decoder(time, "video", name, durationMs)
    }

    override fun onAudioDecoderInitialized(time: AnalyticsListener.EventTime, name: String, timestampMs: Long, durationMs: Long) {
        decoder(time, "audio", name, durationMs)
    }

    private fun decoder(time: AnalyticsListener.EventTime, track: String, name: String, duration: Long) {
        attempt(time)?.let { diagnostics.recordFor(it, "decoder", mapOf("track" to track, "decoder" to name, "init_ms" to duration)) }
    }

    override fun onVideoInputFormatChanged(time: AnalyticsListener.EventTime, format: Format, reuse: DecoderReuseEvaluation?) {
        format(time, "video", format, reuse)
    }

    override fun onAudioInputFormatChanged(time: AnalyticsListener.EventTime, format: Format, reuse: DecoderReuseEvaluation?) {
        format(time, "audio", format, reuse)
    }

    private fun format(time: AnalyticsListener.EventTime, track: String, format: Format, reuse: DecoderReuseEvaluation?) {
        attempt(time)?.let { diagnostics.recordFor(it, "format", mapOf(
            "track" to track, "codec" to format.codecs, "mime" to format.sampleMimeType,
            // Reused decoders may initialize for an earlier source; use the actual reuse result.
            "decoder" to reuse?.takeIf { it.result != DecoderReuseEvaluation.REUSE_RESULT_NO }?.decoderName,
            "width" to format.width, "height" to format.height, "fps" to format.frameRate, "bitrate" to format.bitrate,
        )) }
    }

    override fun onDroppedVideoFrames(time: AnalyticsListener.EventTime, count: Int, elapsedMs: Long) {
        attempt(time)?.let { diagnostics.dropped(it, count) }
    }

    /** Progressive MediaLoadData often says UNKNOWN: label each separate source at construction. */
    fun observe(source: MediaSource, handler: Handler, token: MediaRuntimeDiagnostics.Attempt, track: String): MediaSource {
        source.addEventListener(handler, sourceListener(token, track))
        return source
    }

    fun sourceListener(token: MediaRuntimeDiagnostics.Attempt, track: String): MediaSourceEventListener =
        object : MediaSourceEventListener {
            private fun record(event: String, info: LoadEventInfo, extra: Map<String, Any?> = emptyMap()) {
                diagnostics.recordFor(token, event, mapOf(
                    "track" to track, "load_id" to info.loadTaskId,
                    "duration_ms" to info.loadDurationMs, "bytes" to info.bytesLoaded,
                ) + extra)
            }
            override fun onLoadStarted(window: Int, period: MediaSource.MediaPeriodId?, info: LoadEventInfo, data: MediaLoadData, retryCount: Int) {
                record("load_start", info)
            }
            override fun onLoadCompleted(window: Int, period: MediaSource.MediaPeriodId?, info: LoadEventInfo, data: MediaLoadData) {
                record("load_end", info)
            }
            override fun onLoadCanceled(window: Int, period: MediaSource.MediaPeriodId?, info: LoadEventInfo, data: MediaLoadData) {
                record("load_cancel", info)
            }
            override fun onLoadError(window: Int, period: MediaSource.MediaPeriodId?, info: LoadEventInfo, data: MediaLoadData, error: IOException, wasCanceled: Boolean) {
                record("load_error", info, failureFields(error))
            }
        }

    companion object {
        /** Never serializes exception messages, DataSpecs, URIs, response bodies or headers. */
        fun failureFields(error: Throwable): Map<String, Any?> {
            var current: Throwable? = error
            var timeout = false
            var io = false
            repeat(8) {
                val cause = current ?: return@repeat
                if (cause is HttpDataSource.InvalidResponseCodeException) {
                    return mapOf("cause" to "http", "http_status" to cause.responseCode)
                }
                timeout = timeout || cause is SocketTimeoutException
                io = io || cause is IOException
                current = cause.cause?.takeIf { it !== cause }
            }
            return mapOf("cause" to when { timeout -> "timeout"; io -> "io"; else -> "other" })
        }
    }
}
