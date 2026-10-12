package com.focubili.app

import androidx.media3.datasource.DataSink
import androidx.media3.datasource.DataSpec
import java.io.IOException

/** Caching is optional: a full/pinned budget or disk failure must never abort
 * the upstream bytes already being delivered to the decoder by TeeDataSource.
 * SimpleCache keeps its hole lock until CacheDataSource closes as usual.
 */
internal class OptionalCacheDataSink(
    private val delegate: DataSink,
    private val releaseReservations: (DataSpec) -> Unit = {},
) : DataSink {
    private var currentSpec: DataSpec? = null
    private var disabled = false
    override fun open(dataSpec: DataSpec) {
        disabled = false
        currentSpec = dataSpec
        attempt { delegate.open(dataSpec) }
    }
    override fun write(buffer: ByteArray, offset: Int, length: Int) {
        if (!disabled) attempt { delegate.write(buffer, offset, length) }
    }
    override fun close() {
        if (!disabled) attempt { delegate.close() }
        release()
    }
    private fun release() {
        currentSpec?.let(releaseReservations)
        currentSpec = null
    }
    private fun attempt(operation: () -> Unit) {
        try { operation() } catch (_: IOException) {
            disabled = true
            runCatching { delegate.close() }
            release()
        }
    }
}
