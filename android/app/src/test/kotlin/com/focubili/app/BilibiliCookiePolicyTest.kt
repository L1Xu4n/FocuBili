package com.focubili.app

import org.junit.Assert.*
import org.junit.Test

class BilibiliCookiePolicyTest {
    @Test fun logoutCollectsKnownIdentityNamesDespitePartialOrTotalReadFailure() {
        for (failed in BilibiliCookiePolicy.urls) {
            val names = BilibiliCookiePolicy.namesForClear {
                if (it == failed) throw IllegalStateException()
                "extra=fixture"
            }
            assertTrue(names.containsAll(listOf("SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "extra")))
        }
        assertEquals(4, BilibiliCookiePolicy.namesForClear { throw IllegalStateException() }.size)
    }
    @Test fun apiOnlySessionIsSharedWithoutSupplementingOtherDomains() {
        val domains = mapOf("https://api.bilibili.com" to "SESSDATA=fixture; bili_jct=fixture")
        val snapshot = BilibiliCookiePolicy.inspect(domains::get)
        assertEquals(BilibiliCookiePolicy.State.SESSION, snapshot.state)
        assertTrue(BilibiliCookiePolicy.hasSession(snapshot.header))
    }
    @Test fun partialEmptyIsUnknownAndCompleteEmptyIsAnonymous() {
        val partial = BilibiliCookiePolicy.inspect { url ->
            if (url.endsWith("api.bilibili.com")) throw IllegalStateException()
            null
        }
        assertEquals(BilibiliCookiePolicy.State.UNKNOWN, partial.state)
        assertTrue(partial.partial)
        assertEquals(BilibiliCookiePolicy.State.ANONYMOUS, BilibiliCookiePolicy.inspect { null }.state)
    }
    @Test fun conflictingSessionStillAllowsCollectingNamesForExplicitLogout() {
        val names = BilibiliCookiePolicy.namesForClear { url ->
            if (url.endsWith("api.bilibili.com")) "SESSDATA=fixture-A; extra=one"
            else "SESSDATA=fixture-B; bili_jct=fixture-B"
        }
        assertTrue(names.containsAll(listOf("SESSDATA", "bili_jct", "extra")))
    }
}
