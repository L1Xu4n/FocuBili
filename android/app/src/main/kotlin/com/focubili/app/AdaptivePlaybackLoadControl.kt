package com.focubili.app

import androidx.media3.common.C
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.upstream.Allocator
import androidx.media3.exoplayer.upstream.DefaultAllocator

/** 由一个 Media3 LoadControl 管理分配器、加载状态和固定后向缓冲。 */
@UnstableApi
internal class AdaptivePlaybackLoadControl(
    private val delegate: LoadControl = DefaultLoadControl.Builder()
        .setAllocator(DefaultAllocator(true, C.DEFAULT_BUFFER_SEGMENT_SIZE))
        .setBufferDurationsMsForStreaming(20_000, 30_000, 2_500, 5_000)
        .setPrioritizeTimeOverSizeThresholdsForStreaming(true)
        .setBackBuffer(10_000, true)
        .build(),
    private val profileFor: ((LoadControl.Parameters) -> Profile)? = null,
) : LoadControl {
    enum class Profile { STANDARD, METERED, LOCAL }

    private val period = Timeline.Period()
    private val window = Timeline.Window()

    /** 让 Media3 为本播放器创建或重置加载状态。 */
    override fun onPrepared(playerId: PlayerId) = delegate.onPrepared(playerId)

    /** 使用含播放器和 period 的现代回调更新分配器目标容量。 */
    override fun onTracksSelected(
        parameters: LoadControl.Parameters,
        trackGroups: TrackGroupArray,
        trackSelections: Array<out ExoTrackSelection?>,
    ) = delegate.onTracksSelected(parameters, trackGroups, trackSelections)

    /** 停播时让同一个委托回收该播放器的加载状态。 */
    override fun onStopped(playerId: PlayerId) = delegate.onStopped(playerId)

    /** 释放时清理委托中的播放器状态和分配器占用。 */
    override fun onReleased(playerId: PlayerId) = delegate.onReleased(playerId)

    /** 返回该委托在整个播放器生命周期内使用的分配器。 */
    override fun getAllocator(playerId: PlayerId): Allocator = delegate.getAllocator(playerId)

    /** 将构建时已固定的 10 秒后向时长返回给 Media3。 */
    override fun getBackBufferDurationUs(playerId: PlayerId): Long =
        delegate.getBackBufferDurationUs(playerId)

    /** 后向缓冲从关键帧处保留，支持小幅后退。 */
    override fun retainBackBufferFromKeyframe(playerId: PlayerId): Boolean =
        delegate.retainBackBufferFromKeyframe(playerId)

    /** 起播与重缓冲使用真实媒体时长，网络档位共享 2.5/5 秒阈值。 */
    override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean =
        delegate.shouldStartPlayback(parameters)

    /** 预加载使用 Media3 的原有决策与状态。 */
    override fun shouldContinuePreloading(
        playerId: PlayerId,
        timeline: Timeline,
        mediaPeriodId: MediaPeriodId,
        bufferedDurationUs: Long,
    ): Boolean = delegate.shouldContinuePreloading(playerId, timeline, mediaPeriodId, bufferedDurationUs)

    /** 只缩放省流源的续载时长，将 20/30 秒阈值映射为 10/15 秒，共用 Media3 的滞回和倍速逻辑。 */
    override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
        if (parameters.playerId == PlayerId.PRELOAD) return delegate.shouldContinueLoading(parameters)
        val profile = profileFor?.invoke(parameters) ?: readSourceProfile(parameters)
        if (profile != Profile.METERED) return delegate.shouldContinueLoading(parameters)
        return delegate.shouldContinueLoading(
            LoadControl.Parameters(
                parameters.playerId, parameters.timeline, parameters.mediaPeriodId,
                parameters.playbackPositionUs, parameters.bufferedDurationUs * 2,
                parameters.playbackSpeed, parameters.playWhenReady, parameters.rebuffering,
                parameters.targetLiveOffsetUs, parameters.lastRebufferRealtimeMs,
            ),
        )
    }

    /** 根据 Media3 正在加载的 period 读取随源绑定的档位，避免新源设置影响仍在退出的旧源。 */
    private fun readSourceProfile(parameters: LoadControl.Parameters): Profile {
        val periodIndex = parameters.timeline.getIndexOfPeriod(parameters.mediaPeriodId.periodUid)
        if (periodIndex == C.INDEX_UNSET) return Profile.STANDARD
        val windowIndex = parameters.timeline.getPeriod(periodIndex, period).windowIndex
        return parameters.timeline.getWindow(windowIndex, window).mediaItem.localConfiguration?.tag as? Profile
            ?: Profile.STANDARD
    }
}
