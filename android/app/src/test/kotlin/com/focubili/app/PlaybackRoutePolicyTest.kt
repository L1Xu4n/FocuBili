package com.focubili.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 检查 Android 与 Dart 对校园网、PCDN、备用线路的处理一致。 */
class PlaybackRoutePolicyTest {
    private val campus = "https://cn-jsnj-fx-02-01.bilivideo.com/upgcxcode/video?sign=a%2Fb"
    private val mirror = "https://upos-sz-mirrorali.bilivideo.com/upgcxcode/video?sign=a%2Fb"
    private val pcdn = "https://x.mcdn.bilivideo.cn/v1/resource/video?sign=a%2Fb"

    /** 智能与备用优先不改写签名，主线仍保留兜底。 */
    @Test fun preferAvailableBackups() {
        assertEquals(listOf(mirror, campus), PlaybackRoutePolicy.order(listOf(campus, mirror, mirror), "smart", true))
        assertEquals(listOf(mirror, campus), PlaybackRoutePolicy.order(listOf(campus, mirror), "backup", true))
        assertEquals(listOf(campus), PlaybackRoutePolicy.order(listOf(campus), "backup", true))
    }

    /** 主线加关闭避开开关恢复原顺序；PCDN 仅降低优先级。 */
    @Test fun preserveFallbackAndOriginalOrder() {
        assertEquals(listOf(pcdn, mirror), PlaybackRoutePolicy.order(listOf(pcdn, mirror), "primary", false))
        assertEquals(listOf(mirror, pcdn), PlaybackRoutePolicy.order(listOf(pcdn, mirror), "primary", true))
        assertTrue(PlaybackRoutePolicy.isPcdn("$mirror&os=mcdn"))
        assertFalse(PlaybackRoutePolicy.isPcdn(campus))
        assertEquals(listOf(pcdn), PlaybackRoutePolicy.order(listOf(pcdn), "smart", true))
    }
}
