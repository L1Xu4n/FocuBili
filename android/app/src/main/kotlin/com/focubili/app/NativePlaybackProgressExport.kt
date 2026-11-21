package com.focubili.app

/** A pure projection of one native preferences snapshot; never normalizes or edits storage. */
internal object NativePlaybackProgressExport {
    private const val ID = "(?:[bB][vV][0-9A-Za-z]{10}|(?:cheese:ss|CHEESE:SS)[1-9][0-9]*)"
    private val lastKey = Regex("^last-part:($ID):(cid|page)$")
    private val partKey = Regex("^progress:($ID):([1-9][0-9]*):(position|duration|updated_at)$")
    private const val MAX_TIMESTAMP_MS = 253402300799999L

    private data class Part(val bvid: String, val cid: Long)

    fun read(values: Map<String, *>): Map<String, Any> {
        val originalIds = mutableMapOf<String, String>()
        fun identity(raw: String): String {
            val canonical = if (raw.startsWith("cheese:ss")) {
                "CHEESE:SS" + raw.removePrefix("cheese:ss")
            } else raw
            if (canonical.startsWith("CHEESE:SS")) {
                require(canonical.removePrefix("CHEESE:SS").toLongOrNull()?.let { it > 0L } == true)
            }
            require(originalIds[canonical]?.let { it == raw } != false)
            originalIds[canonical] = raw
            return canonical
        }
        val last = mutableMapOf<String, MutableMap<String, Any>>()
        val parts = mutableMapOf<Part, MutableMap<String, Any>>()
        for ((key, value) in values) {
            when {
                key.startsWith("last-part:") -> {
                    val match = requireNotNull(lastKey.matchEntire(key))
                    val bvid = identity(match.groupValues[1])
                    val row = last.getOrPut(bvid) { mutableMapOf("bvid" to bvid) }
                    if (match.groupValues[2] == "cid") {
                        require(value is Long && value > 0L)
                        row["cid"] = value
                    } else {
                        require(value is Int && value > 0)
                        row["pageNumber"] = value
                    }
                }
                key.startsWith("progress:") -> {
                    val match = requireNotNull(partKey.matchEntire(key))
                    val bvid = identity(match.groupValues[1])
                    val cid = requireNotNull(match.groupValues[2].toLongOrNull())
                    require(cid > 0L && value is Long && value >= 0L)
                    val part = Part(bvid, cid)
                    val row = parts.getOrPut(part) { mutableMapOf("bvid" to bvid, "cid" to cid) }
                    val field = when (match.groupValues[3]) {
                        "position" -> "positionMs"
                        "duration" -> "durationMs"
                        else -> "savedAtMs"
                    }
                    row[field] = value
                }
                // Other keys are outside the progress schema, including any credentials.
                else -> Unit
            }
        }
        for (row in last.values) {
            require(row.containsKey("cid") && row.containsKey("pageNumber"))
        }
        for (row in parts.values) {
            val position = row["positionMs"] as Long?
            val duration = row["durationMs"] as Long?
            require((position == null) == (duration == null))
            if (position != null && duration != null) {
                require(duration > 0L && position <= duration)
            }
            val savedAt = row["savedAtMs"] as Long?
            require(savedAt == null || savedAt <= MAX_TIMESTAMP_MS)
            // Timestamp-only rows represent intentionally cleared/completed positions.
            require(position != null || savedAt != null)
        }
        return mapOf(
            "format" to "focubili.native-playback-progress",
            "version" to 1,
            "lastParts" to last.toSortedMap().values.map { it.toMap() },
            "parts" to parts.entries
                .sortedWith(compareBy({ it.key.bvid }, { it.key.cid }))
                .map { it.value.toMap() },
        )
    }
}
