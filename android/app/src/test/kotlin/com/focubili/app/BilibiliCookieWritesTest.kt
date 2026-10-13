package com.focubili.app

import org.junit.Assert.*
import org.junit.Test

class BilibiliCookieWritesTest {
    @Test fun throwingSubmissionStillWaitsForAlreadyPendingWrites() {
        val pending = mutableListOf<(Boolean) -> Unit>()
        val results = mutableListOf<Boolean>()
        var flushes = 0
        BilibiliCookieWrites.apply(listOf("a" to "fixture", "b" to "fixture", "c" to "fixture"),
            { url, _, done -> if (url == "b") throw IllegalStateException() else pending.add(done) },
            { flushes++ }, results::add)
        assertTrue(results.isEmpty())
        pending.first()(true)
        assertTrue(results.isEmpty())
        pending.last()(true)
        assertEquals(listOf(false), results)
        assertEquals(1, flushes)
        pending.last()(true)
        assertEquals(1, results.size)
    }

    @Test fun deniedWriteAndFlushFailureAreReportedWithoutHanging() {
        for (accepted in listOf(true, false)) {
            val results = mutableListOf<Boolean>()
            BilibiliCookieWrites.apply(listOf("a" to "fixture"), { _, _, done -> done(accepted) },
                { if (accepted) throw IllegalStateException() }, results::add)
            assertEquals(listOf(false), results)
        }
    }

    @Test fun successfulBatchFinishesOnlyOnceAfterAllCallbacks() {
        val pending = mutableListOf<(Boolean) -> Unit>()
        val results = mutableListOf<Boolean>()
        BilibiliCookieWrites.apply(List(3) { "domain" to "fixture" },
            { _, _, done -> pending.add(done) }, {}, results::add)
        pending.reversed().forEach { it(true) }
        assertEquals(listOf(true), results)
    }
}
