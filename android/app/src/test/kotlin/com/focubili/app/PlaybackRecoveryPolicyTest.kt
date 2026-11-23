package com.focubili.app

import androidx.media3.common.C
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证播放器恢复策略会覆盖全部音视频候选组合且兼容无独立音轨的视频。 */
class PlaybackRecoveryPolicyTest {
    /** Media3 每条线路使用三次重试预算，只有失效地址绕过换线进入刷新。 */
    @Test
    fun mediaRetryBudgetAndRefreshBoundaryAreSeparate() {
        val policy = DefaultLoadErrorHandlingPolicy(PlaybackRecoveryPolicy.MEDIA_MINIMUM_RETRY_COUNT)
        assertEquals(3, policy.getMinimumLoadableRetryCount(C.DATA_TYPE_MEDIA))
        for (status in listOf(403, 404, 410)) {
            assertTrue(PlaybackRecoveryPolicy.shouldRefreshPlayurlImmediately(status))
        }
        for (status in listOf(null, 401, 429, 500, 502, 503)) {
            assertFalse(PlaybackRecoveryPolicy.shouldRefreshPlayurlImmediately(status))
        }
    }

    /** 两条视频和两条音频必须生成四个不重复组合，而不是旧实现的两个同序号组合。 */
    @Test
    fun twoVideoAndAudioCandidatesUseCrossProduct() {
        val selections = (0 until PlaybackRecoveryPolicy.candidateCount(2, 2)).map { attempt ->
            PlaybackRecoveryPolicy.candidateAt(attempt, videoCount = 2, audioCount = 2)
        }

        assertEquals(
            listOf(
                PlaybackCandidateSelection(videoIndex = 0, audioIndex = 0),
                PlaybackCandidateSelection(videoIndex = 1, audioIndex = 1),
                PlaybackCandidateSelection(videoIndex = 1, audioIndex = 0),
                PlaybackCandidateSelection(videoIndex = 0, audioIndex = 1),
            ),
            selections,
        )
    }

    /** 没有独立音频的渐进式视频仍会依次尝试全部视频地址。 */
    @Test
    fun videoOnlyCandidatesDoNotInventAudioTrack() {
        val selections = (0 until PlaybackRecoveryPolicy.candidateCount(3, 0)).map { attempt ->
            PlaybackRecoveryPolicy.candidateAt(attempt, videoCount = 3, audioCount = 0)
        }

        assertEquals(
            listOf(
                PlaybackCandidateSelection(videoIndex = 0, audioIndex = null),
                PlaybackCandidateSelection(videoIndex = 1, audioIndex = null),
                PlaybackCandidateSelection(videoIndex = 2, audioIndex = null),
            ),
            selections,
        )
    }
}
