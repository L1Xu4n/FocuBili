package com.focubili.app

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class LatestPlaybackRequestQueueTest {
    private fun await(latch: CountDownLatch) = assertTrue("Timed out waiting for controlled worker", latch.await(5, TimeUnit.SECONDS))
    private fun awaitIgnoringInterrupt(latch: CountDownLatch) {
        while (true) {
            try { if (latch.await(5, TimeUnit.SECONDS)) return else error("Latch timed out") }
            catch (_: InterruptedException) { /* Model socket I/O that needs disconnect. */ }
        }
    }

    @Test fun cancellationAfterFetchBeforeMainThreadPublicationInvalidatesTheResult() {
        val queue = LatestPlaybackRequestQueue()
        val fetched = CountDownLatch(1)
        val pendingPublication = AtomicReference<() -> Unit>()
        val published = AtomicInteger()
        try {
            queue.submit { request ->
                pendingPublication.set { if (request.isActive) published.incrementAndGet() }
                fetched.countDown()
            }
            await(fetched)
            queue.cancel()
            pendingPublication.get().invoke()
            assertEquals(0, published.get())
        } finally { queue.close() }
    }

    @Test fun rapidSwitchDropsAllPendingSupersededRequests() {
        val queue = LatestPlaybackRequestQueue()
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val done = CountDownLatch(1)
        val fetched = Collections.synchronizedList(mutableListOf<Int>())
        try {
            queue.submit {
                fetched.add(1); entered.countDown(); awaitIgnoringInterrupt(release)
                assertFalse(it.isActive)
            }
            await(entered)
            for (i in 2..99) queue.submit { fetched.add(i) }
            queue.submit { fetched.add(100); done.countDown() }
            release.countDown(); await(done)
            assertEquals(listOf(1, 100), fetched)
        } finally { release.countDown(); queue.close() }
    }

    @Test fun disconnectUnblocksOldRequestAndCannotCloseNewConnection() {
        val queue = LatestPlaybackRequestQueue()
        val entered = CountDownLatch(1); val oldDisconnected = CountDownLatch(1)
        val newEntered = CountDownLatch(1); val releaseNew = CountDownLatch(1); val newDone = CountDownLatch(1)
        val oldCloses = AtomicInteger(); val newCloses = AtomicInteger()
        try {
            queue.submit { request ->
                request.own { oldCloses.incrementAndGet(); oldDisconnected.countDown() }.use {
                    entered.countDown(); awaitIgnoringInterrupt(oldDisconnected)
                }
            }
            await(entered)
            queue.submit { request ->
                request.own { newCloses.incrementAndGet() }.use {
                    newEntered.countDown(); awaitIgnoringInterrupt(releaseNew)
                }
                newDone.countDown()
            }
            await(newEntered)
            assertEquals(1, oldCloses.get())
            assertEquals(0, newCloses.get())
            releaseNew.countDown(); await(newDone)
            assertEquals(1, newCloses.get())
        } finally { releaseNew.countDown(); queue.close() }
    }

    @Test fun cancellationBeforeConnectionRegistrationClosesLateConnectionOnce() {
        val pendingCloses = mutableListOf<() -> Unit>()
        val request = LatestPlaybackRequestQueue.Request { pendingCloses.add(it) }
        var closes = 0
        request.cancel()
        assertThrows(CancellationException::class.java) { request.own { closes++ } }
        assertThrows(CancellationException::class.java) { request.checkActive() }
        pendingCloses.forEach { it() }
        request.cancel()
        assertEquals(1, closes)
    }

    @Test fun normalFinallyRacingQueuedCancellationIsIdempotent() {
        val pendingCloses = mutableListOf<() -> Unit>()
        val request = LatestPlaybackRequestQueue.Request { pendingCloses.add(it) }
        var closes = 0
        val first = request.own { closes++ }
        first.close()
        val second = request.own { closes++ }
        request.cancel()
        second.close()
        pendingCloses.forEach { it() }
        assertEquals(2, closes)
    }

    @Test fun closeCancelsRunningAndPendingAndRejectsNewWork() {
        val queue = LatestPlaybackRequestQueue()
        val entered = CountDownLatch(1); val disconnected = CountDownLatch(1); val release = CountDownLatch(1); val finished = CountDownLatch(1)
        val ran = AtomicInteger()
        try {
            queue.submit { request ->
                request.own { disconnected.countDown() }.use {
                    entered.countDown(); awaitIgnoringInterrupt(release)
                }
                finished.countDown()
            }
            await(entered)
            queue.submit { ran.incrementAndGet() }
            queue.close(); queue.close()
            queue.submit { ran.incrementAndGet() }
            await(disconnected)
            release.countDown(); await(finished)
            assertEquals(0, ran.get())
        } finally { release.countDown(); queue.close() }
    }
}
