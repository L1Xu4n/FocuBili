package com.focubili.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证部分视频播放失败对应的编码优先级与缓存隔离规则。 */
class PlaybackTrackPolicyTest {
    /** 复现 v1.7 的低清 AVC 压过目标高清 HEVC；新策略必须先满足清晰度。 */
    @Test
    fun requestedHdHevcWinsOver360pAvcInEitherOrder() {
        val avc = PlaybackTrackPolicy.compatibilityScore("avc1.fixture") + 360_000_000L
        val hevc = PlaybackTrackPolicy.compatibilityScore("hvc1.fixture") + 1080_000_000L
        assertTrue(PlaybackTrackPolicy.shouldReplaceTrack(80, hevc, 16, avc, 80))
        assertFalse(PlaybackTrackPolicy.shouldReplaceTrack(16, avc, 80, hevc, 80))
        assertTrue(PlaybackTrackPolicy.shouldReplaceTrack(80, avc, 80, hevc, 80))
        assertFalse(PlaybackTrackPolicy.shouldReplaceTrack(120, avc, 80, hevc, 80))
    }

    @Test
    fun missingTargetUsesHighestLowerQualityAndAudioRetainsScoreOrdering() {
        assertTrue(PlaybackTrackPolicy.shouldReplaceTrack(64, 100, 16, 10000, 80))
        assertFalse(PlaybackTrackPolicy.shouldReplaceTrack(0, 10000, 16, 1, 80))
        assertTrue(PlaybackTrackPolicy.shouldReplaceTrack(30216, 100, 30280, 50, null))
    }

    @Test
    fun actualQualityCacheKeysCannotReuseLegacyMislabeledBytes() {
        val low = PlaybackTrackPolicy.mediaCacheKey("fixture", 1L, 16, "avc1", true)
        val high = PlaybackTrackPolicy.mediaCacheKey("fixture", 1L, 80, "avc1", true)
        assertFalse(low == high)
        assertFalse(high == "fixture:1:80:avc1:video")
        assertTrue(high.startsWith("focubili-quality-v2:"))
    }

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

    /** 默认清晰度不可用时只接受相同或更低档位，不能在移动网络意外升级。 */
    @Test
    fun qualityFallbackOnlyMovesDownward() {
        assertTrue(PlaybackTrackPolicy.isAtOrBelowPreferred(64, 80))
        assertTrue(PlaybackTrackPolicy.isAtOrBelowPreferred(80, 80))
        assertFalse(PlaybackTrackPolicy.isAtOrBelowPreferred(116, 80))
        assertFalse(PlaybackTrackPolicy.isAtOrBelowPreferred(0, 80))
    }

    /** x86 模拟器必须禁用异步解码，ARM 真机继续保留 Media3 默认路径。 */
    @Test
    fun synchronousCodecIsLimitedToDesktopEmulatorAbis() {
        assertTrue(PlaybackTrackPolicy.shouldUseSynchronousCodec(listOf("x86_64", "arm64-v8a")))
        assertTrue(PlaybackTrackPolicy.shouldUseSynchronousCodec(listOf("x86")))
        assertFalse(PlaybackTrackPolicy.shouldUseSynchronousCodec(listOf("arm64-v8a", "armeabi-v7a")))
    }
}
