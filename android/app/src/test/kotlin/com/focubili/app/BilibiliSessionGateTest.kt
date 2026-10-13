package com.focubili.app

import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class BilibiliSessionGateTest {
    @Before fun reset() { BilibiliSessionGate.endWrite() }

    @Test fun delayedResponseRechecksUnobservedBrowserAccountChange() {
        var browserCookie = "SESSDATA=fixture-A"
        val request = BilibiliSessionGate.read { browserCookie }
        // HTTP 尚未返回，网页端已经写入另一个账号，应用未执行中间轮询。
        browserCookie = "SESSDATA=fixture-B"
        assertTrue(BilibiliSessionGate.isCurrent(request.generation))
        assertFalse(BilibiliSessionGate.validateResponse(request.generation) { browserCookie })
        assertFalse(BilibiliSessionGate.isCurrent(request.generation))
        val fresh = BilibiliSessionGate.read { browserCookie }
        assertTrue(BilibiliSessionGate.validateResponse(fresh.generation) { browserCookie })
    }

    @Test fun guestResponseWithStillUnknownSessionRemainsValid() {
        val guest = BilibiliSessionGate.read { throw IllegalStateException() }
        assertEquals(BilibiliCookiePolicy.State.UNKNOWN, guest.state)
        assertTrue(BilibiliSessionGate.validateResponse(guest.generation) { throw IllegalStateException() })
    }

    @Test fun guestResponseRechecksUnobservedLoginBeforePublication() {
        val guest = BilibiliSessionGate.read { throw IllegalStateException() }
        // 游客请求发出后 WebView 完成登录，尚未有任何应用端轮询。
        assertTrue(BilibiliSessionGate.isCurrent(guest.generation))
        assertFalse(BilibiliSessionGate.validateResponse(guest.generation) { "SESSDATA=fixture-new-login" })
        assertFalse(BilibiliSessionGate.isCurrent(guest.generation))
    }

    @Test fun responseCannotBePublishedWhenSessionReadBecomesUnknown() {
        val request = BilibiliSessionGate.read { "SESSDATA=fixture-A" }
        assertFalse(BilibiliSessionGate.validateResponse(request.generation) { throw IllegalStateException() })
    }

    @Test fun accountReplacementInvalidatesOldRequestsAndHidesPartialWrites() {
        val old = BilibiliSessionGate.read { "SESSDATA=fixture-A" }
        assertTrue(BilibiliSessionGate.isCurrent(old.generation))
        assertTrue(BilibiliSessionGate.beginWrite())
        assertFalse(BilibiliSessionGate.beginWrite())
        assertFalse(BilibiliSessionGate.isCurrent(old.generation))
        val during = BilibiliSessionGate.read { "SESSDATA=fixture-B" }
        assertEquals(BilibiliCookiePolicy.State.CHANGING, during.state)
        assertTrue(during.header.isEmpty())
        BilibiliSessionGate.endWrite()
        val fresh = BilibiliSessionGate.read { "SESSDATA=fixture-B" }
        assertEquals(BilibiliCookiePolicy.State.SESSION, fresh.state)
        assertTrue(BilibiliSessionGate.isCurrent(fresh.generation))
        assertFalse(BilibiliSessionGate.isCurrent(old.generation))
    }

    @Test fun browserSessionChangeAndLogoutInvalidateOldRequestAndGuestConsent() {
        val old = BilibiliSessionGate.read { "SESSDATA=fixture-A" }
        val fresh = BilibiliSessionGate.read { "SESSDATA=fixture-B" }
        assertFalse(BilibiliSessionGate.isCurrent(old.generation))
        val signedOut = BilibiliSessionGate.read { null }
        assertEquals(BilibiliCookiePolicy.State.ANONYMOUS, signedOut.state)
        assertFalse(BilibiliSessionGate.isCurrent(fresh.generation))
        val unknown = BilibiliSessionGate.read { throw IllegalStateException() }
        assertEquals(BilibiliCookiePolicy.State.UNKNOWN, unknown.state)
        assertTrue(BilibiliSessionGate.isCurrent(unknown.generation))
        BilibiliSessionGate.read { "SESSDATA=fixture-C" }
        assertFalse(BilibiliSessionGate.isCurrent(unknown.generation))
    }

    @Test fun mutationDuringDomainReadCannotPublishATornSessionSnapshot() {
        var first = true
        val snapshot = BilibiliSessionGate.read {
            if (first) {
                first = false
                assertTrue(BilibiliSessionGate.beginWrite())
                BilibiliSessionGate.endWrite()
            }
            "SESSDATA=fixture-B"
        }
        assertEquals(BilibiliCookiePolicy.State.CHANGING, snapshot.state)
        assertTrue(snapshot.header.isEmpty())
    }

    @Test fun newlyObservedConflictInvalidatesEarlierSession() {
        val before = BilibiliSessionGate.read { "SESSDATA=fixture-A" }
        val conflict = BilibiliSessionGate.read { url ->
            if (url.endsWith("api.bilibili.com")) "SESSDATA=fixture-A" else "SESSDATA=fixture-B"
        }
        assertEquals(BilibiliCookiePolicy.State.CONFLICT, conflict.state)
        assertFalse(BilibiliSessionGate.isCurrent(before.generation))
    }
}
