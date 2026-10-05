package com.focubili.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 无 Android 设备即可验证冷启动、暖启动和重复消费的路由行为。 */
class SubscriptionNotificationTapStateTest {
    @Test
    fun normalLaunchDoesNotInventTap() {
        val state = SubscriptionNotificationTapState()
        assertFalse(state.consume())
        assertFalse(state.consume())
    }

    @Test
    fun coldTapWaitsForDartAndIsConsumedOnlyOnce() {
        val state = SubscriptionNotificationTapState()
        assertFalse(state.capture())
        assertTrue(state.consume())
        assertFalse(state.consume())
    }

    @Test
    fun tapsBeforeListenerAreCoalescedIntoOneNavigation() {
        val state = SubscriptionNotificationTapState()
        assertFalse(state.capture())
        assertFalse(state.capture())
        assertTrue(state.consume())
        assertFalse(state.consume())
    }

    @Test
    fun warmTapIsDispatchedImmediatelyAndNotReplayed() {
        val state = SubscriptionNotificationTapState()
        assertFalse(state.consume())
        assertTrue(state.capture())
        assertFalse(state.consume())
        assertTrue(state.capture())
        assertFalse(state.consume())
    }

    @Test
    fun differentEnginesDoNotShareTapState() {
        val foreground = SubscriptionNotificationTapState()
        val background = SubscriptionNotificationTapState()
        assertFalse(foreground.capture())
        assertFalse(background.consume())
        assertTrue(foreground.consume())
    }
}
