package com.focubili.app

/** 集中判断播放或暂停回调是否可以把原生播放器恢复为就绪阶段。 */
internal object PlaybackPhasePolicy {
    /** 播放已经结束或失败时保留终态，避免稍后的暂停回调覆盖完播事件。 */
    fun shouldReturnToReady(
        playbackPrepared: Boolean,
        playbackEnded: Boolean,
        playbackFailed: Boolean,
    ): Boolean {
        return playbackPrepared && !playbackEnded && !playbackFailed
    }
}
