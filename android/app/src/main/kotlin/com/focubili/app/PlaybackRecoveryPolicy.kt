package com.focubili.app

/** 保存一次 DASH 播放尝试实际使用的视频和音频候选序号。 */
internal data class PlaybackCandidateSelection(
    val videoIndex: Int,
    val audioIndex: Int?,
)

/**
 * 集中计算音视频主备地址的交叉组合，避免播放器只尝试同序号线路。
 *
 * 该策略不依赖 Android UI，可由 JVM 单元测试直接验证，并可供未来桌面播放器复用同一规则。
 */
internal object PlaybackRecoveryPolicy {
    /** 返回所有视频与音频候选的组合数量；没有独立音轨时只轮换视频候选。 */
    fun candidateCount(videoCount: Int, audioCount: Int): Int {
        val safeVideoCount = videoCount.coerceAtLeast(1)
        val safeAudioCount = audioCount.coerceAtLeast(1)
        return safeVideoCount * safeAudioCount
    }

    /**
     * 将扁平尝试序号转换为视频、音频候选。
     *
     * 视频线路先轮换，随后再更换音频线路，所以 2×2 的顺序为 1+1、2+1、1+2、2+2。
     */
    fun candidateAt(
        attemptIndex: Int,
        videoCount: Int,
        audioCount: Int,
    ): PlaybackCandidateSelection {
        val safeVideoCount = videoCount.coerceAtLeast(1)
        val safeAudioCount = audioCount.coerceAtLeast(1)
        val maximumAttempt = safeVideoCount * safeAudioCount - 1
        val safeAttempt = attemptIndex.coerceIn(0, maximumAttempt)
        return PlaybackCandidateSelection(
            videoIndex = safeAttempt % safeVideoCount,
            audioIndex = if (audioCount > 0) safeAttempt / safeVideoCount else null,
        )
    }
}
