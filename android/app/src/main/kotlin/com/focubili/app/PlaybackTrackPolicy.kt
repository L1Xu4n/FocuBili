package com.focubili.app

import java.util.Locale

/** 集中定义播放器的视频编码兼容优先级和编码缓存键规则。 */
internal object PlaybackTrackPolicy {
    private const val AVC_TRACK_SCORE = 10_000_000_000_000L
    private const val HEVC_TRACK_SCORE = 100_000_000_000L
    private const val MAX_CODEC_CACHE_KEY_LENGTH = 40

    /** 给 AVC/H.264 最高兼容分，HEVC 次之，未知或 AV1 编码保持最低优先级。 */
    fun compatibilityScore(codec: String): Long {
        val normalized = codec.trim().lowercase(Locale.ROOT)
        return when {
            normalized.startsWith("avc1") || normalized.startsWith("avc3") ->
                AVC_TRACK_SCORE
            normalized.startsWith("hev1") || normalized.startsWith("hvc1") ->
                HEVC_TRACK_SCORE
            else -> 0L
        }
    }

    /** 把不可信编码名称限制成稳定安全的缓存键，空名称使用 unknown。 */
    fun cacheKey(codec: String): String {
        return codec
            .trim()
            .lowercase(Locale.ROOT)
            .replace(Regex("[^0-9a-z._-]"), "_")
            .take(MAX_CODEC_CACHE_KEY_LENGTH)
            .ifBlank { "unknown" }
    }
}
