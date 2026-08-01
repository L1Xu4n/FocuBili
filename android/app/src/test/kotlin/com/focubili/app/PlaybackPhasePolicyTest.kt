package com.focubili.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 验证播放和暂停回调不会覆盖播放器已经进入的结束或错误阶段。 */
class PlaybackPhasePolicyTest {
    /** 普通播放或暂停变化仍应把已经准备好的播放器保持在就绪阶段。 */
    @Test
    fun preparedPlaybackCanReturnToReady() {
        assertTrue(
            PlaybackPhasePolicy.shouldReturnToReady(
                playbackPrepared = true,
                playbackEnded = false,
                playbackFailed = false,
            ),
        )
    }

    /** 完播后的暂停回调必须保留结束阶段，让 Flutter 能显示互动选项。 */
    @Test
    fun endedPlaybackCannotReturnToReady() {
        assertFalse(
            PlaybackPhasePolicy.shouldReturnToReady(
                playbackPrepared = true,
                playbackEnded = true,
                playbackFailed = false,
            ),
        )
    }

    /** 播放失败后的状态变化必须保留错误阶段和原始错误提示。 */
    @Test
    fun failedPlaybackCannotReturnToReady() {
        assertFalse(
            PlaybackPhasePolicy.shouldReturnToReady(
                playbackPrepared = true,
                playbackEnded = false,
                playbackFailed = true,
            ),
        )
    }
}
