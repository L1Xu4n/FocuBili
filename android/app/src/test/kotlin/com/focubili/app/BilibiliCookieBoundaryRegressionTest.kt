package com.focubili.app

import org.junit.Assert.*
import org.junit.Test

/** 安全边界回归：只使用虚构内存快照，不接触真实账号。 */
class BilibiliCookieBoundaryRegressionTest {
    @Test fun crossAccountIdentityConflictIsRejected() {
        val domains = mapOf(
            "https://www.bilibili.com" to "SESSDATA=fixture-A; bili_jct=fixture-A; DedeUserID=111",
            "https://passport.bilibili.com" to "bili_jct=fixture-B; DedeUserID=222",
        )
        assertTrue(runCatching { BilibiliCookiePolicy.readHeader(domains::get) }.isFailure)
    }

    @Test fun differentSessionsAreRejectedRatherThanLastDomainWinning() {
        val domains = mapOf(
            "https://www.bilibili.com" to "SESSDATA=fixture-A",
            "https://api.bilibili.com" to "SESSDATA=fixture-B",
        )
        assertTrue(runCatching { BilibiliCookiePolicy.readHeader(domains::get) }.isFailure)
    }

    @Test fun missingAccountFieldsAreNotBorrowedFromAnotherDomain() {
        val domains = mapOf(
            "https://www.bilibili.com" to "SESSDATA=fixture-A",
            "https://passport.bilibili.com" to "bili_jct=fixture-other; DedeUserID=222",
        )
        val header = BilibiliCookiePolicy.readHeader(domains::get)
        assertTrue(BilibiliCookiePolicy.hasSession(header))
        assertFalse(header.contains("bili_jct="))
        assertFalse(header.contains("DedeUserID="))
    }

    @Test fun partialReadsOnlyTrustAnIntactApiDomainSnapshot() {
        for (mask in 1..7) {
            val failed = BilibiliCookiePolicy.urls.filterIndexed { index, _ -> mask and (1 shl index) != 0 }
            val snapshot = BilibiliCookiePolicy.inspect { url ->
                if (url in failed) throw IllegalStateException()
                "SESSDATA=fixture-A"
            }
            assertEquals(if (BilibiliCookiePolicy.urls.first() in failed) BilibiliCookiePolicy.State.UNKNOWN
                else BilibiliCookiePolicy.State.SESSION, snapshot.state)
            assertEquals(failed.size < 3, snapshot.partial)
        }
        val emptyApi = BilibiliCookiePolicy.inspect { url ->
            if (url.endsWith("passport.bilibili.com")) throw IllegalStateException()
            if (url.endsWith("www.bilibili.com")) "SESSDATA=fixture-A" else null
        }
        assertEquals(BilibiliCookiePolicy.State.UNKNOWN, emptyApi.state)
        assertTrue(emptyApi.header.isEmpty())
    }

    @Test fun duplicateDifferentSessionCookiesInOneSnapshotAreRejected() {
        assertTrue(runCatching {
            BilibiliCookiePolicy.readHeader { "SESSDATA=fixture-A; SESSDATA=fixture-B" }
        }.isFailure)
    }

    @Test fun normalSignedOutStillReturnsEmptyHeader() {
        assertTrue(BilibiliCookiePolicy.readHeader { null }.isEmpty())
    }

    @Test fun allFailedReadsAreNotReportedAsConfirmedAnonymous() {
        assertTrue(runCatching {
            BilibiliCookiePolicy.readHeader { throw IllegalStateException() }
        }.isFailure)
    }
}
