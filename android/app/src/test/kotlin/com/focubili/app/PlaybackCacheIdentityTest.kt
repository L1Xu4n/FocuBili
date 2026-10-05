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

    private fun key(
        representation: PlaybackCacheRepresentation = track,
        bvid: String = "BV1GJ411x7h7",
        cid: Long = 456L,
        video: Boolean = false,
    ) = PlaybackCacheIdentity.key(bvid, cid, 80, video, representation)

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

    @Test
    fun warmLegacyAndOtherRepresentationEntriesCannotBeRead() {
        // 模拟持久缓存已含旧版键及低码率表示，升级后不能命中这些字节。
        val legacyKey = "BV1GJ411x7h7:456:80:mp4a.40.2:audio"
        val warmCache = mutableMapOf(
            legacyKey to "legacy bytes",
            key(track.copy(bandwidth = 128000)) to "lower bitrate bytes",
        )
        assertNull(warmCache[key()])
        warmCache[key()] = "current bytes"
        assertEquals("current bytes", warmCache[key(track.copy(resourceUrl =
            "https://b.bilivideo.com/upgcxcode/123/456/456_nb3-1-30280.m4s?sign=fresh"))])
        assertEquals("legacy bytes", warmCache[legacyKey])
        assertTrue(key().startsWith("focubili-media-v2:"))
    }
}
