package com.focubili.app

import android.os.Handler
import android.os.Looper
import android.os.SystemClock

/** 以单调时钟执行睡眠定时；独立于 Flutter 生命周期，取消后旧回调不会触发。 */
class PlaybackSleepTimer(private val onExpired: () -> Unit) {
    private val handler = Handler(Looper.getMainLooper())
    private var deadline = 0L
    private val tick = object : Runnable {
        /** 到期暂停，尚未到期则按剩余时长重新排队。 */
        override fun run() { check() }
    }

    /** 安排或取消定时，拒绝非法时长；零表示关闭。 */
    fun configure(durationMs: Long) {
        require(durationMs in 0L..604_800_000L)
        handler.removeCallbacks(tick)
        deadline = if (durationMs == 0L) 0L else SystemClock.elapsedRealtime() + durationMs
        if (deadline != 0L) handler.postDelayed(tick, durationMs)
    }

    /** 后台播放持有播放器唤醒锁；恢复或心跳时补查设备睡眠期间已到期的定时。 */
    fun check() {
        if (deadline == 0L) return
        val remaining = deadline - SystemClock.elapsedRealtime()
        handler.removeCallbacks(tick)
        if (remaining <= 0L) {
            deadline = 0L
            onExpired()
        } else {
            handler.postDelayed(tick, remaining)
        }
    }

    /** 向界面提供单调时钟计算的剩余毫秒，0 表示没有正在运行的定时。 */
    fun remainingMs(): Long = if (deadline == 0L) 0L else (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(0L)
}
