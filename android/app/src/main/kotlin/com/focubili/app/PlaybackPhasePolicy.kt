package com.focubili.app

/** 集中判断播放或暂停回调是否可以把原生播放器恢复为就绪阶段。 */
internal object PlaybackPhasePolicy {
    /** 仅真实 READY 可以恢复就绪，保留重缓冲、完播和错误状态。 */
    fun shouldReturnToReady(
        playbackPrepared: Boolean,
        playbackEnded: Boolean,
        playbackFailed: Boolean,
        playbackReady: Boolean,
    ): Boolean {
        return playbackPrepared && playbackReady && !playbackEnded && !playbackFailed
    }
}
