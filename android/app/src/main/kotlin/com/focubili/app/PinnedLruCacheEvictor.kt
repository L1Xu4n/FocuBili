package com.focubili.app

import androidx.media3.common.C
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheEvictor
import androidx.media3.datasource.cache.CacheSpan
import java.util.TreeSet

/** Media3 owns span/index/file locking. All state below is guarded by Cache's
 * monitor, including pin changes. Current representations are never evicted;
 * when their budget is full CacheDataSource falls back to uncached networking.
 */
internal class PinnedLruCacheEvictor(private val maximumBytes: Long) : CacheEvictor {
    private val spans = TreeSet<CacheSpan> { left, right ->
        val touched = left.lastTouchTimestamp.compareTo(right.lastTouchTimestamp)
        if (touched != 0) touched else left.compareTo(right)
    }
    private var bytes = 0L
    private var pinnedKeys: Set<String> = emptySet()
    private val reservations = mutableMapOf<Pair<String, Long>, Long>()

    fun pin(cache: Cache, keys: Set<String>) = synchronized(cache) {
        pinnedKeys = keys.toSet()
        // Empty pins are only installed after player.release() closes writers.
        if (keys.isEmpty()) reservations.clear()
        evict(cache, 0L)
    }
    override fun requiresCacheSpanTouches() = true
    override fun onCacheInitialized() = Unit

    override fun onStartFile(cache: Cache, key: String, position: Long, length: Long) {
        // Unknown lengths cannot be reserved safely; bypass this cache write.
        if (length == C.LENGTH_UNSET.toLong() || length > maximumBytes) {
            throw Cache.CacheException("Cache write exceeds available budget")
        }
        val reserved = reservations.values.sum()
        evict(cache, length + reserved)
        if (bytes > maximumBytes - length - reserved) {
            throw Cache.CacheException("Active media occupies cache budget")
        }
        reservations[key to position] = length
    }
    override fun onSpanAdded(cache: Cache, span: CacheSpan) {
        reservations.remove(span.key to span.position)
        if (spans.add(span)) bytes += span.length
        evict(cache, 0L)
    }
    override fun onSpanRemoved(cache: Cache, span: CacheSpan) {
        if (spans.remove(span)) bytes -= span.length
    }
    override fun onSpanTouched(cache: Cache, oldSpan: CacheSpan, newSpan: CacheSpan) {
        onSpanRemoved(cache, oldSpan)
        onSpanAdded(cache, newSpan)
    }
    private fun evict(cache: Cache, incoming: Long) {
        while (bytes > maximumBytes - incoming) {
            val victim = spans.firstOrNull { it.key !in pinnedKeys } ?: return
            cache.removeSpan(victim)
            // Real SimpleCache calls onSpanRemoved synchronously. Defensive
            // removal also prevents a failed/missing callback from looping.
            onSpanRemoved(cache, victim)
        }
    }
}
