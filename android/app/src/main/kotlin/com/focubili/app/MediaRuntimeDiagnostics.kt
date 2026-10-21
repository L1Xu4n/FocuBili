package com.focubili.app

/** Bounded, memory-only measurements. Never accepts URLs, headers, titles or exception messages. */
internal class MediaRuntimeDiagnostics(private val clock: () -> Long) {
    data class Attempt(val session: Long, val number: Long)
    private val events = ArrayDeque<Map<String, Any>>()
    private var session = 0L
    private var attempt = 0L
    private var started = 0L
    private var preparedAt = 0L
    private var firstFrame = false
    private var firstFrameMs: Long? = null
    private var prepareToFrameMs: Long? = null
    private val trackSummaries = mutableMapOf<String, Map<String, Any>>()
    private var everReady = false
    private var seeking = false
    private var state = "idle"
    private var bufferSince: Long? = null
    private var rebufferSince: Long? = null
    private var bufferReason = "initial"
    private var rebufferCount = 0L
    private var rebufferMs = 0L
    private var droppedFrames = 0L
    private var bufferedMs = 0L
    private var positionMs = 0L
    private var playRequested = false
    private var speed = 1.0
    private var active = false
    private var hasData = false

    fun begin(local: Boolean) {
        finish("superseded")
        session++
        attempt = 0
        started = clock()
        firstFrame = false
        firstFrameMs = null
        prepareToFrameMs = null
        trackSummaries.clear()
        everReady = false
        seeking = false
        state = "idle"
        bufferSince = null
        rebufferSince = null
        rebufferCount = 0
        rebufferMs = 0
        droppedFrames = 0
        bufferedMs = 0
        positionMs = 0
        playRequested = false
        speed = 1.0
        active = true
        record("open", mapOf("local" to local))
    }

    fun prepare(): Attempt {
        endBuffer()
        attempt++
        preparedAt = clock()
        seeking = false
        state = "idle"
        trackSummaries.clear()
        record("prepare")
        return Attempt(session, attempt)
    }

    fun accepts(value: Attempt) = active && value.session == session && value.number == attempt

    fun recordFor(value: Attempt, event: String, fields: Map<String, Any?> = emptyMap()) {
        if (!accepts(value)) return
        if (event == "format" || event == "decoder") {
            val safe = safeFields(fields)
            (safe["track"] as? String)?.let { track -> trackSummaries[track] = trackSummaries[track].orEmpty() + safe }
        }
        record(event, fields)
    }

    fun firstFrame(value: Attempt) {
        if (!accepts(value) || firstFrame) return
        firstFrame = true
        firstFrameMs = elapsed(started)
        prepareToFrameMs = elapsed(preparedAt)
        record("first_frame", mapOf("first_frame_ms" to firstFrameMs, "prepare_to_frame_ms" to prepareToFrameMs))
    }

    fun dropped(value: Attempt, count: Int) {
        if (accepts(value)) droppedFrames = (droppedFrames + count.coerceAtLeast(0)).coerceAtMost(MAX_NUMBER)
    }

    fun seek() {
        if (!active) return
        seeking = true
        if (bufferSince != null) {
            endBuffer()
            bufferReason = "seek"
            bufferSince = clock()
        }
        record("seek")
    }

    /** A seek within buffered data can stay READY without another state callback. */
    fun seekReturned(ready: Boolean) {
        if (ready) seeking = false
    }

    fun sample(position: Long, buffered: Long, playingIntent: Boolean, playbackSpeed: Float) {
        if (active && bufferSince != null && bufferReason == "rebuffer") {
            if (!playingIntent) {
                rebufferSince?.let { rebufferMs += elapsed(it) }
                rebufferSince = null
            } else if (rebufferSince == null) {
                rebufferSince = clock()
            }
        }
        positionMs = position.coerceIn(0L, MAX_NUMBER)
        bufferedMs = buffered.coerceIn(0L, MAX_NUMBER)
        playRequested = playingIntent
        speed = playbackSpeed.toDouble()
    }

    fun state(next: String) {
        if (!active || next == state) return
        endBuffer()
        if (next == "buffering") {
            bufferReason = when {
                seeking -> "seek"
                state == "idle" && attempt > 1 -> "recovery"
                everReady && playRequested -> "rebuffer"
                else -> "initial"
            }
            bufferSince = clock()
            if (bufferReason == "rebuffer") {
                rebufferCount++
                rebufferSince = clock()
            }
        }
        state = next
        record("state", mapOf("state" to next, "buffer_reason" to bufferReason,
            "buffered_ms" to bufferedMs, "play_requested" to playRequested, "speed" to speed))
        if (next == "ready") {
            everReady = true
            seeking = false
        }
    }

    fun finish(reason: String) {
        if (!active) return
        endBuffer()
        trackSummaries.values.forEach { record("track_summary", it) }
        record("summary", summary() + ("reason" to reason))
        active = false
    }

    private fun endBuffer() {
        bufferSince?.let { since ->
            val duration = elapsed(since)
            rebufferSince?.let { rebufferMs += elapsed(it) }
            record("buffer_end", mapOf("duration_ms" to duration, "buffer_reason" to bufferReason))
        }
        bufferSince = null
        rebufferSince = null
    }

    private fun summary(): Map<String, Any?> = mapOf(
        "state" to state, "position_ms" to positionMs, "buffered_ms" to bufferedMs,
        "play_requested" to playRequested, "speed" to speed, "dropped_frames" to droppedFrames,
        "first_frame_ms" to firstFrameMs, "prepare_to_frame_ms" to prepareToFrameMs,
        "rebuffer_count" to rebufferCount,
        "rebuffer_ms" to rebufferMs + (rebufferSince?.let(::elapsed) ?: 0L),
    )

    private fun elapsed(since: Long) = (clock() - since).coerceIn(0L, MAX_NUMBER)

    fun record(event: String, fields: Map<String, Any?> = emptyMap()) {
        if (!active || event !in EVENTS) return
        hasData = true
        events.addLast(entry(event, fields))
        while (events.size > MAX_EVENTS) events.removeFirst()
    }

    private fun entry(event: String, fields: Map<String, Any?>): Map<String, Any> =
        safeFields(fields) + mapOf("event" to event, "session_id" to session,
            "attempt" to attempt, "elapsed_ms" to elapsed(started))

    fun snapshot(): List<Map<String, Any>> = events.toList().let {
        if (active && hasData) {
            val tracks = trackSummaries.values.map { fields -> entry("track_summary", fields) }
            it.takeLast(MAX_EVENTS - 1 - tracks.size) + tracks + entry("summary", summary())
        } else it
    }

    fun clear() {
        events.clear()
        hasData = false
        rebufferCount = 0
        rebufferMs = 0
        droppedFrames = 0
        firstFrameMs = null
        prepareToFrameMs = null
        trackSummaries.clear()
        // Do not republish old history; future events in the same active source still work.
        if (bufferSince != null) bufferSince = clock()
        if (rebufferSince != null) rebufferSince = clock()
    }

    companion object {
        const val MAX_EVENTS = 64
        const val MAX_NUMBER = 9_007_199_254_740_991L
        val EVENTS = setOf("open", "request", "prepare", "state", "seek", "first_frame",
            "buffer_end", "load_start", "load_end", "load_error", "load_cancel", "decoder",
            "format", "player_error", "summary", "track_summary")
        private val numbers = setOf("request_id", "queue_ms", "source_ms", "api_ms", "duration_ms", "bytes",
            "load_id", "error_code", "http_status", "first_frame_ms", "prepare_to_frame_ms",
            "buffered_ms", "position_ms", "rebuffer_count", "rebuffer_ms", "dropped_frames",
            "width", "height", "bitrate", "quality", "video_candidate", "audio_candidate", "init_ms")
        private val enums = mapOf(
            "track" to setOf("video", "audio", "muxed"),
            "state" to setOf("idle", "buffering", "ready", "ended"),
            "buffer_reason" to setOf("initial", "rebuffer", "seek", "recovery"),
            "reason" to setOf("superseded", "released", "error"),
            "outcome" to setOf("success", "error"),
            "cause" to setOf("timeout", "http", "io", "other"),
            "mime" to setOf("video/avc", "video/hevc", "video/av01", "video/mp4v-es",
                "audio/mp4a-latm", "audio/opus", "audio/flac", "audio/eac3", "audio/ac3"),
        )
        fun safeFields(fields: Map<String, Any?>): Map<String, Any> = buildMap {
            fields.forEach { (key, value) ->
                when {
                    key in numbers && value is Number && value.toDouble().isFinite() &&
                        value.toDouble() == value.toLong().toDouble() && value.toLong() in 0..MAX_NUMBER -> put(key, value.toLong())
                    key in setOf("local", "play_requested", "cache_bypass") && value is Boolean -> put(key, value)
                    key == "speed" && value is Number && value.toDouble() in 0.1..5.0 -> put(key, value.toDouble())
                    key == "fps" && value is Number && value.toDouble() in 0.1..1000.0 -> put(key, value.toDouble())
                    value is String && enums[key]?.contains(value) == true -> put(key, value)
                    key == "decoder" && value is String && Regex("(?:OMX\\.|c2\\.)[A-Za-z0-9_.-]{1,90}").matches(value) -> put(key, value)
                    key == "codec" && value is String && Regex("(?:avc[13]|hev1|hvc1|av01|mp4a)(?:\\.[A-Za-z0-9]{1,12}){1,6}").matches(value) -> put(key, value)
                }
            }
        }
    }
}
