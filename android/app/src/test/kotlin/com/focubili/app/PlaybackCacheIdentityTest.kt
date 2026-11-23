package com.focubili.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackCacheIdentityTest {
    private val track = PlaybackCacheRepresentation(
        id = 30280, bandwidth = 192000, codec = "mp4a.40.2", mimeType = "audio/mp4",
        initialization = "0-907", indexRange = "908-1234",
        resourceUrl = "https://a.bilivideo.com/upgcxcode/123/456/456_nb3-1-30280.m4s?deadline=1&sign=old",
    )

    /** 为测试轨道生成与播放器一致的缓存键。 */
    private fun key(
        representation: PlaybackCacheRepresentation = track,
        bvid: String = "BV1GJ411x7h7",
        cid: Long = 456L,
        video: Boolean = false,
        quality: Int = 80,
        selectedUrl: String = representation.resourceUrl,
    ) = PlaybackCacheIdentity.key(bvid, cid, quality, video, representation, selectedUrl)

    /** 同一条音轨跨视频档位复用，视频键仍随实际 QN 变化。 */
    @Test
    fun audioReusesBytesAcrossVideoQualityChanges() {
        assertEquals(key(quality = 64), key(quality = 80))
        assertNotEquals(key(video = true, quality = 64), key(video = true, quality = 80))
    }

    /** 同路径的多个官方镜像归一为同一资源，调换主备不影响键。 */
    @Test
    fun uniqueOfficialMirrorPathSurvivesPcdnAndUposReordering() {
        val pcdn = "https://node.mcdn.bilivideo.com/v1/resource/temporary.m4s?os=mcdn"
        val upos = "https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/audio.m4s?old=1"
        val mirror = "https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/1/audio.m4s?new=1"
        val first = PlaybackCacheIdentity.withResourceUrls(track, listOf(pcdn, upos, mirror))
        val second = PlaybackCacheIdentity.withResourceUrls(track, listOf(mirror, pcdn, upos))
        assertEquals(upos, first.resourceUrl)
        assertEquals(key(first, selectedUrl = pcdn), key(second, selectedUrl = mirror))
        assertEquals(pcdn, PlaybackCacheIdentity.withResourceUrls(track, listOf(pcdn)).resourceUrl)
    }

    /** 镜像路径有冲突时按实际选择的线路路径隔离，包括同一列表内换线。 */
    @Test
    fun conflictingPathsStaySeparateWhenSwitchingRoutes() {
        val first = "https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1/audio.m4s"
        val second = "https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/1/reencoded.m4s"
        val forward = PlaybackCacheIdentity.withResourceUrls(track, listOf(first, second))
        val backward = PlaybackCacheIdentity.withResourceUrls(track, listOf(second, first))
        assertTrue(forward.hasConflictingMirrorPaths)
        assertNotEquals(key(forward), key(backward))
        assertNotEquals(key(forward, selectedUrl = first), key(forward, selectedUrl = second))
        assertEquals(key(backward, selectedUrl = first), key(forward, selectedUrl = first))
    }

    @Test
    fun representationIdAndBitrateSeparateSameCodecAudio() {
        assertNotEquals(key(), key(track.copy(id = 30232)))
        assertNotEquals(key(), key(track.copy(bandwidth = 128000)))
    }

    @Test
    fun videoPartCodecAndTrackTypeRemainIsolated() {
        assertNotEquals(key(), key(bvid = "BV1Q541167Qg"))
        assertNotEquals(key(), key(cid = 457L))
        assertNotEquals(key(), key(video = true))
        assertNotEquals(key(), key(track.copy(codec = "ec-3")))
        assertEquals(key(), key(track.copy(codec = " MP4A.40.2 ")))
    }

    @Test
    fun signedUrlRefreshAndCdnChangesReuseIdenticalBytes() {
        assertEquals(key(), key(track.copy(resourceUrl =
            "https://backup.bilivideo.com/upgcxcode/123/456/456_nb3-1-30280.m4s?deadline=999&sign=new")))
    }

    @Test
    fun newResourceAndSegmentLayoutDoNotReuseOldBytes() {
        assertNotEquals(key(), key(track.copy(resourceUrl =
            "https://a.bilivideo.com/upgcxcode/123/456/reencoded.m4s?sign=new")))
        assertNotEquals(key(), key(track.copy(initialization = "0-999")))
        assertNotEquals(key(), key(track.copy(indexRange = "1000-1999")))
        assertNotEquals(key(), key(track.copy(width = 1920, height = 1080)))
    }

    /** 历史命名空间和不同轨道的条目不能命中当前键。 */
    @Test
    fun warmLegacyAndOtherRepresentationEntriesCannotBeRead() {
        // 模拟持久缓存已含旧版键及低码率表示，升级后不能命中这些字节。
        val legacyKey = "BV1GJ411x7h7:456:80:mp4a.40.2:audio"
        val v2Key = key().replace("focubili-media-v3:", "focubili-media-v2:")
        val warmCache = mutableMapOf(
            legacyKey to "legacy bytes",
            v2Key to "v2 bytes",
            key(track.copy(bandwidth = 128000)) to "lower bitrate bytes",
        )
        assertNull(warmCache[key()])
        warmCache[key()] = "current bytes"
        assertEquals("current bytes", warmCache[key(track.copy(resourceUrl =
            "https://b.bilivideo.com/upgcxcode/123/456/456_nb3-1-30280.m4s?sign=fresh"))])
        assertEquals("legacy bytes", warmCache[legacyKey])
        assertEquals("v2 bytes", warmCache[v2Key])
        assertTrue(key().startsWith("focubili-media-v3:"))
    }
}
