package com.focubili.app

/** 集中定义 Android 续播位置的有效性与恢复状态，保持与 Flutter、Windows 相同语义。 */
internal object PlaybackResumePolicy {
    private const val COMPLETED_REMAINING_MS = 3_000L

    /** 校验本机保存的位置；时长未知、位置无效或距结尾三秒时返回零。 */
    fun normalizeStoredPosition(positionMs: Long, durationMs: Long): Long {
        if (positionMs <= 0L || durationMs <= 0L) {
            return 0L
        }
        val clampedPosition = positionMs.coerceAtMost(durationMs)
        return if (durationMs - clampedPosition <= COMPLETED_REMAINING_MS) {
            0L
        } else {
            clampedPosition
        }
    }

    /** 校验 Flutter 明确传入的位置，阻止负数进入 Media3 时间轴。 */
    fun normalizeRequestedPosition(positionMs: Long): Long {
        return positionMs.coerceAtLeast(0L)
    }

    /** 判断当前保存动作是否应该删除时间点，同时保留最后分P选择。 */
    fun shouldClearStoredPosition(positionMs: Long, durationMs: Long): Boolean {
        return normalizeStoredPosition(positionMs, durationMs) == 0L
    }

    /** 仅在非零恢复位置尚未进入 Media3 就绪态时向 Flutter 报告恢复中。 */
    fun shouldReportRestoring(
        restoredPositionMs: Long,
        playbackPrepared: Boolean,
    ): Boolean {
        return restoredPositionMs > 0L && !playbackPrepared
    }
}
