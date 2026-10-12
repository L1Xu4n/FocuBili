package com.focubili.app

import androidx.media3.datasource.DataSink
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheSpan
import androidx.media3.datasource.cache.CacheEvictor
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.lang.reflect.Proxy

class PinnedLruCacheEvictorTest {
    private fun span(key: String, used: Long, size: Long = 4L, position: Long = 0L) =
        CacheSpan(key, position, size, used, File("unused-test-span"))
    private fun cache(evictor: CacheEvictor, removed: MutableList<CacheSpan>): Cache =
        Proxy.newProxyInstance(Cache::class.java.classLoader, arrayOf(Cache::class.java)) { proxy, method, args ->
            if (method.name == "removeSpan") {
                val value = args!![0] as CacheSpan
                removed.add(value)
                evictor.onSpanRemoved(proxy as Cache, value)
            }
            null
        } as Cache

    @Test fun baselineEvictsActiveRepresentationUnderTheSamePressure() {
        val old = LeastRecentlyUsedCacheEvictor(8)
        val removed = mutableListOf<CacheSpan>(); val cache = cache(old, removed)
        old.onSpanAdded(cache,span("current",1,8))
        old.onStartFile(cache,"next",0,4)
        assertEquals(listOf("current"),removed.map { it.key })
        // The equivalent pinned-cache case below retains current and defers writes.
    }
    @Test fun accessTouchProtectsRecentlyReadSpan() {
        val evictor = PinnedLruCacheEvictor(8)
        val removed = mutableListOf<CacheSpan>(); val cache = cache(evictor, removed)
        val a = span("A", 1); val b = span("B", 2)
        evictor.onSpanAdded(cache,a); evictor.onSpanAdded(cache,b)
        evictor.onSpanTouched(cache,a,span("A",3))
        evictor.onStartFile(cache,"C",0,4)
        assertEquals(listOf("B"), removed.map { it.key })
        evictor.onSpanAdded(cache,span("C",4))
        assertEquals(1,removed.size)
    }
    @Test fun pinnedResourceSurvivesPressureAndFullBudgetDefersWrites() {
        val evictor = PinnedLruCacheEvictor(8)
        val removed = mutableListOf<CacheSpan>(); val cache = cache(evictor, removed)
        evictor.pin(cache,setOf("current"))
        evictor.onSpanAdded(cache,span("current",1,8))
        assertThrows(Cache.CacheException::class.java) { evictor.onStartFile(cache,"next",0,4) }
        assertTrue(removed.isEmpty())
        evictor.pin(cache,emptySet())
        evictor.onStartFile(cache,"next",0,4)
        assertEquals("current",removed.single().key)
    }
    @Test fun concurrentVideoAudioReservationsCannotOvercommit() {
        val evictor = PinnedLruCacheEvictor(8)
        val removed = mutableListOf<CacheSpan>(); val cache = cache(evictor, removed)
        evictor.pin(cache,setOf("video","audio"))
        evictor.onStartFile(cache,"video",0,4)
        evictor.onStartFile(cache,"audio",0,4)
        assertThrows(Cache.CacheException::class.java) { evictor.onStartFile(cache,"other",0,1) }
        evictor.onSpanAdded(cache,span("video",1))
        evictor.onSpanAdded(cache,span("audio",2))
        assertThrows(Cache.CacheException::class.java) { evictor.onStartFile(cache,"other",0,1) }
        assertTrue(removed.isEmpty())
    }
    @Test fun failedWriterReleasesOnlyItsOwnRangeReservation() {
        val evictor = PinnedLruCacheEvictor(8)
        val removed = mutableListOf<CacheSpan>(); val cache = cache(evictor, removed)
        evictor.onStartFile(cache, "video", 0, 4)
        evictor.onStartFile(cache, "video", 10, 4)
        evictor.releaseReservations(cache, "video", 0, 4)
        evictor.onStartFile(cache, "audio", 0, 4)
        assertThrows(Cache.CacheException::class.java) { evictor.onStartFile(cache, "other", 0, 1) }
    }
    @Test fun startupSpansAreTrimmedBeforePlaybackPinsExist() {
        val evictor = PinnedLruCacheEvictor(4)
        val removed = mutableListOf<CacheSpan>(); val cache = cache(evictor, removed)
        evictor.onSpanAdded(cache,span("recent",3));evictor.onSpanAdded(cache,span("old",1))
        assertEquals("old",removed.single().key)
    }
    @Test fun optionalCacheWriteFailureNeverInterruptsMediaBytes() {
        var writes=0;var closes=0
        val sink=OptionalCacheDataSink(object: DataSink {
            override fun open(spec: DataSpec) = Unit
            override fun write(buffer:ByteArray,offset:Int,length:Int) { writes++;throw IOException("simulated full disk") }
            override fun close() { closes++ }
        })
        sink.write(byteArrayOf(1,2),0,2);sink.write(byteArrayOf(3),0,1);sink.close()
        assertEquals(1,writes);assertEquals(1,closes)
    }
}
