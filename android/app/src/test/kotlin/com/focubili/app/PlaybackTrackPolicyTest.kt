package com.focubili.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证部分视频播放失败对应的编码优先级与缓存隔离规则。 */
class PlaybackTrackPolicyTest {
    /** AVC 应始终比 HEVC 和 AV1 获得更高兼容分，优先选择稳定轨道。 */
    @Test
    fun avcIsPreferredOverHevcAndAv1() {
        val avcScore = PlaybackTrackPolicy.compatibilityScore("avc1.640033")
        val hevcScore = PlaybackTrackPolicy.compatibilityScore("hvc1.1.6.L120.90")
        val av1Score = PlaybackTrackPolicy.compatibilityScore("av01.0.08M.08")

        assertTrue(avcScore > hevcScore)
        assertTrue(hevcScore > av1Score)
    }

    /** 不同编码必须生成不同安全键，避免旧 HEVC 数据污染 AVC 缓存。 */
    @Test
    fun codecCacheKeysAreSafeAndSeparated() {
        assertEquals("avc1.640033", PlaybackTrackPolicy.cacheKey("AVC1.640033"))
        assertEquals("hvc1.1.6.l120.90", PlaybackTrackPolicy.cacheKey("hvc1.1.6.L120.90"))
        assertEquals("unknown", PlaybackTrackPolicy.cacheKey("   "))
        assertEquals("bad_codec", PlaybackTrackPolicy.cacheKey("bad codec"))
    }
}
