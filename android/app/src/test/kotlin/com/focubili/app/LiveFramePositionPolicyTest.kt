package com.focubili.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LiveFramePositionPolicyTest {
    @Test
    fun labelsOnlyShortContinuousCopies() {
        assertEquals(20_016L, LiveFramePositionPolicy.estimate(20_000L, 20_032L, 15L))
        assertEquals(20_000L, LiveFramePositionPolicy.estimate(20_000L, 20_000L, 15L))
        assertNull(LiveFramePositionPolicy.estimate(20_000L, 10_000L, 15L))
        assertNull(LiveFramePositionPolicy.estimate(20_000L, 20_351L, 15L))
        assertNull(LiveFramePositionPolicy.estimate(20_000L, 20_010L, 351L))
        assertNull(LiveFramePositionPolicy.estimate(-1L, 20_010L, 15L))
    }
}
