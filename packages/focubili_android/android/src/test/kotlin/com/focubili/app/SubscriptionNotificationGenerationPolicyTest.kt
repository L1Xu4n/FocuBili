package com.focubili.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 后台旧任务不能在停用、重新启用或清理订阅后继续发送迟到通知。 */
class SubscriptionNotificationGenerationPolicyTest {
    private fun allowed(
        enabled: Boolean = true,
        notificationsEnabled: Boolean = true,
        backgroundRefreshEnabled: Boolean = true,
        storedGeneration: Long? = 7L,
        expectedGeneration: Long = 7L,
        background: Boolean = true,
    ): Boolean = SubscriptionNotificationGenerationPolicy.isAllowed(
        enabled,
        notificationsEnabled,
        backgroundRefreshEnabled,
        storedGeneration,
        expectedGeneration,
        background,
    )

    @Test
    fun currentBackgroundGenerationIsAllowed() {
        assertTrue(allowed())
    }

    @Test
    fun changedGenerationRejectsOldAndFutureWork() {
        assertFalse(allowed(expectedGeneration = 6L))
        assertFalse(allowed(expectedGeneration = 8L))
    }

    @Test
    fun disabledSubscriptionsRejectBothForegroundAndBackground() {
        assertFalse(allowed(enabled = false))
        assertFalse(allowed(enabled = false, background = false))
    }

    @Test
    fun disabledNotificationsRejectBothForegroundAndBackground() {
        assertFalse(allowed(notificationsEnabled = false))
        assertFalse(allowed(notificationsEnabled = false, background = false))
    }

    @Test
    fun backgroundRequiresItsOwnOptIn() {
        assertFalse(allowed(backgroundRefreshEnabled = false))
        assertTrue(allowed(backgroundRefreshEnabled = false, background = false))
    }

    @Test
    fun absentAndNegativeGenerationFailClosed() {
        assertFalse(allowed(storedGeneration = null))
        assertFalse(allowed(storedGeneration = -1L, expectedGeneration = -1L))
    }

    @Test
    fun fullLengthIntegerGenerationIsNotTruncated() {
        val generation = Int.MAX_VALUE.toLong() + 20L
        assertTrue(allowed(storedGeneration = generation, expectedGeneration = generation))
        assertFalse(allowed(storedGeneration = generation, expectedGeneration = 19L))
    }
}
