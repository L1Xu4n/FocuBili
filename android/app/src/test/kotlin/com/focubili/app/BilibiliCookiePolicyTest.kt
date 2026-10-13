package com.focubili.app

import org.junit.Assert.*
import org.junit.Test

/** 纯内存域容器，不接触设备 Cookie 或真实账号。 */
class BilibiliCookiePolicyTest {
    @Test fun loginAndPlaybackFindApiOnlySession() {
        val domains = mapOf("https://api.bilibili.com" to "SESSDATA=synthetic; bili_jct=synthetic")
        val loginValues = BilibiliCookiePolicy.readValues(domains::get)
        val playbackHeader = BilibiliCookiePolicy.readHeader(domains::get)
        assertTrue(loginValues.containsKey("SESSDATA"))
        assertTrue(BilibiliCookiePolicy.hasSession(playbackHeader))
        assertEquals(2, loginValues.size)
    }

    @Test fun rootAndPassportSessionsUseExistingLoginPrecedence() {
        val values = BilibiliCookiePolicy.readValues { url ->
            if (url.endsWith("passport.bilibili.com")) "SESSDATA=second"
            else "SESSDATA=first; invalid name=x; empty=; path_token=a=b"
        }
        assertTrue(values["SESSDATA"] == "second")
        assertTrue(values["path_token"] == "a=b")
        assertFalse(values.containsKey("invalid name"))
        assertFalse(values.containsKey("empty"))
    }

    @Test fun readFailureNeverReturnsPartialOrAnonymousSession() {
        var failed = false
        try {
            BilibiliCookiePolicy.readHeader { url ->
                if (url.endsWith("api.bilibili.com")) throw IllegalStateException()
                "SESSDATA=synthetic"
            }
        } catch (_: IllegalStateException) { failed = true }
        assertTrue(failed)
        assertFalse(BilibiliCookiePolicy.hasSession(BilibiliCookiePolicy.readHeader { null }))
    }
}
