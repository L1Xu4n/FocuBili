package com.focubili.app

import java.util.concurrent.CancellationException
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** One running API request and at most one pending replacement. No Android/UI dependencies. */
internal class LatestPlaybackRequestQueue : AutoCloseable {
    private val worker = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, LinkedBlockingQueue<Runnable>())
    private val closer = Executors.newSingleThreadExecutor()
    private var current: Request? = null
    private var task: FutureTask<Unit>? = null
    private var closed = false

    @Synchronized fun submit(work: (Request) -> Unit) {
        if (closed) return
        cancel()
        val request = Request { action ->
            try { closer.execute { runCatching(action) } }
            catch (_: RejectedExecutionException) { runCatching(action) }
        }
        current = request
        val next = FutureTask<Unit> {
            if (request.isActive) work(request)
        }
        task = next
        worker.execute(next)
    }

    @Synchronized fun cancel() {
        current?.cancel()
        task?.cancel(true)
        worker.queue.clear()
        current = null
        task = null
    }

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        cancel()
        worker.shutdownNow()
        // Already queued disconnects must complete, even after Activity destruction.
        closer.shutdown()
    }

    internal class Request(private val disconnect: (() -> Unit) -> Unit) {
        private val cancelled = AtomicBoolean(false)
        private val leases = mutableSetOf<Lease>()
        val isActive: Boolean get() = !cancelled.get()

        fun checkActive() {
            if (!isActive) throw CancellationException("Playback request superseded")
        }

        /** Register before any blocking I/O. Cancellation closes this exact connection only. */
        fun own(close: () -> Unit): Lease {
            val lease = Lease(close)
            synchronized(leases) {
                if (isActive) {
                    leases.add(lease)
                    return lease
                }
            }
            disconnect { lease.close() }
            throw CancellationException("Playback request superseded")
        }

        fun cancel() {
            val owned = synchronized(leases) {
                if (!cancelled.compareAndSet(false, true)) return
                leases.toList().also { leases.clear() }
            }
            owned.forEach { lease -> disconnect { lease.close() } }
        }

        inner class Lease(private val closeConnection: () -> Unit) : AutoCloseable {
            private val closed = AtomicBoolean(false)
            override fun close() {
                synchronized(leases) { leases.remove(this) }
                if (closed.compareAndSet(false, true)) closeConnection()
            }
        }
    }
}
