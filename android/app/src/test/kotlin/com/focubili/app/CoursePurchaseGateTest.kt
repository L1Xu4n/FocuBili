package com.focubili.app

import org.junit.Assert.*
import org.junit.Test

class CoursePurchaseGateTest {
    @Test fun findsPurchasedSeasonAcrossPages() {
        val calls = mutableListOf<Int>()
        CoursePurchaseGate.verify(2L, { true }) { page ->
            calls.add(page)
            CoursePurchasePage(2, listOf(CoursePurchaseItem(page.toLong(), false, false)))
        }
        assertEquals(listOf(1, 2), calls)
    }
    @Test fun deniesUnpurchasedExpiredUnavailableAndChangingSessions() {
        for (item in listOf(CoursePurchaseItem(9L, false, false), CoursePurchaseItem(2L, true, false), CoursePurchaseItem(2L, false, true))) {
            assertThrows(CoursePurchaseException::class.java) {
                CoursePurchaseGate.verify(2L, { true }) { CoursePurchasePage(1, listOf(item)) }
            }
        }
        var checks = 0
        assertThrows(CoursePurchaseException::class.java) {
            CoursePurchaseGate.verify(2L, { checks++ == 0 }) { CoursePurchasePage(1, listOf(CoursePurchaseItem(2L, false, false))) }
        }
    }
    @Test fun repeatedOrMalformedPagesCannotGrantAccess() {
        for (page in listOf(CoursePurchasePage(3, emptyList()), CoursePurchasePage(-1, emptyList()), CoursePurchasePage(3, listOf(CoursePurchaseItem(1L, false, false))))) {
            assertThrows(CoursePurchaseException::class.java) { CoursePurchaseGate.verify(2L, { true }) { page } }
        }
    }
}
