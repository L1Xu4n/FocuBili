package com.focubili.app

/** PixelCopy does not return a frame PTS. Keep only a short, continuous read. */
internal object LiveFramePositionPolicy {
    const val SEEK_SETTLE_MS = 250L
    const val MAXIMUM_COPY_WINDOW_MS = 350L

    fun estimate(beforeMs: Long, afterMs: Long, elapsedMs: Long): Long? {
        if (beforeMs < 0L || afterMs < beforeMs ||
            afterMs - beforeMs > MAXIMUM_COPY_WINDOW_MS ||
            elapsedMs !in 0L..MAXIMUM_COPY_WINDOW_MS
        ) return null
        return beforeMs + (afterMs - beforeMs) / 2L
    }
}
