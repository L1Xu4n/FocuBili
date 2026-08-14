package com.focubili.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证 Android 与共享续播计划使用相同的三秒完播边界和恢复生命周期。 */
class PlaybackResumePolicyTest {
    /** 普通中途位置应完整保留，供 Media3 在 prepare 前定位。 */
    @Test
    fun middlePositionRemainsAvailable() {
        assertEquals(47_000L, PlaybackResumePolicy.normalizeStoredPosition(47_000L, 120_000L))
    }

    /** 距结尾恰好三秒的位置应视为已完成，避免下次打开停在结尾。 */
    @Test
    fun completedBoundaryReturnsZero() {
        assertEquals(0L, PlaybackResumePolicy.normalizeStoredPosition(117_000L, 120_000L))
    }

    /** 未知时长无法证明位置安全，应从零开始但继续保留最后分P。 */
    @Test
    fun unknownDurationReturnsZero() {
        assertEquals(0L, PlaybackResumePolicy.normalizeStoredPosition(47_000L, 0L))
    }

    /** 恢复门控只覆盖准备阶段，并在首个 ready 快照中关闭。 */
    @Test
    fun restoringGateClosesWhenPrepared() {
        assertTrue(PlaybackResumePolicy.shouldReportRestoring(47_000L, playbackPrepared = false))
        assertFalse(PlaybackResumePolicy.shouldReportRestoring(47_000L, playbackPrepared = true))
        assertFalse(PlaybackResumePolicy.shouldReportRestoring(0L, playbackPrepared = false))
    }
}
