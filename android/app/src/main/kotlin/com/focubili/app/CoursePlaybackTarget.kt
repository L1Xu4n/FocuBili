package com.focubili.app

/** Classroom identity is separate from BV IDs and is never converted into UGC. */
internal class CoursePlaybackTarget private constructor(
    val seasonId: Long,
    val episodeId: Long,
    val aid: Long,
) {
    val referer: String get() = "https://www.bilibili.com/cheese/play/ep$episodeId"

    fun parameters(cid: Long, quality: Int, dashFlag: Int): Map<String, String> {
        require(cid > 0 && quality > 0)
        return mapOf(
            "avid" to aid.toString(), "ep_id" to episodeId.toString(),
            "cid" to cid.toString(), "qn" to quality.toString(),
            "fnver" to "0", "fnval" to dashFlag.toString(), "fourk" to "1",
        )
    }

    companion object {
        private val KEY = Regex("^cheese:ss([1-9][0-9]*)$")
        private fun seasonId(key: String): Long? =
            KEY.matchEntire(key)?.groupValues?.get(1)?.toLongOrNull()?.takeIf { it > 0 }

        fun isCourseKey(key: String): Boolean = seasonId(key) != null
        fun seasonPage(key: String): String? = seasonId(key)?.let {
            "https://www.bilibili.com/cheese/play/ss$it"
        }
        fun create(key: String, episodeId: Long?, aid: Long?): CoursePlaybackTarget? {
            val season = seasonId(key) ?: return null
            if (episodeId == null || episodeId <= 0 || aid == null || aid <= 0) return null
            return CoursePlaybackTarget(season, episodeId, aid)
        }
    }
}
