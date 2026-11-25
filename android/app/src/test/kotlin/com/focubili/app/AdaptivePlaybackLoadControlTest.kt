package com.focubili.app

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.MediaSource.MediaPeriodId
import androidx.media3.exoplayer.source.SinglePeriodTimeline
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.upstream.Allocator
import androidx.media3.exoplayer.upstream.DefaultAllocator
import com.focubili.app.AdaptivePlaybackLoadControl.Profile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AdaptivePlaybackLoadControlTest {
    private val player = PlayerId.UNSET
    private val timeline = SinglePeriodTimeline(60_000_000L, true, false, false, null, MediaItem.EMPTY)

    /** 构造包含当前播放器和 period 的 Media3 1.10.1 回调参数。 */
    private fun parameters(
        bufferedUs: Long,
        speed: Float = 1f,
        rebuffering: Boolean = false,
    ): LoadControl.Parameters = LoadControl.Parameters(
        player, timeline, MediaPeriodId(timeline.getUidOfPeriod(0)), 123_000L,
        bufferedUs, speed, true, rebuffering, C.TIME_UNSET, 456L,
    )

    /** 使用真实 DefaultLoadControl 验证切换档位时的最小、最大和起播阈值。 */
    @Test
    fun networkProfilesUseDifferentForwardWindowsAndSameStartupThresholds() {
        var profile = Profile.STANDARD
        val control = AdaptivePlaybackLoadControl(profileFor = { profile })
        control.onPrepared(player)
        assertEquals(10_000_000L, control.getBackBufferDurationUs(player))
        assertTrue(control.retainBackBufferFromKeyframe(player))
        val allocator = control.getAllocator(player)
        assertEquals(C.DEFAULT_BUFFER_SEGMENT_SIZE, allocator.individualAllocationLength)
        assertTrue(control.shouldContinueLoading(parameters(19_999_999L)))
        assertTrue(control.shouldContinueLoading(parameters(29_999_999L)))
        assertFalse(control.shouldContinueLoading(parameters(30_000_000L)))
        assertFalse(control.shouldContinueLoading(parameters(20_000_000L)))
        assertTrue(control.shouldContinueLoading(parameters(19_999_999L)))

        profile = Profile.METERED
        assertFalse(control.shouldContinueLoading(parameters(15_000_000L)))
        assertFalse(control.shouldContinueLoading(parameters(10_000_000L)))
        assertTrue(control.shouldContinueLoading(parameters(9_999_999L)))
        assertTrue(control.shouldContinueLoading(parameters(14_999_999L)))
        assertFalse(control.shouldContinueLoading(parameters(15_000_000L, speed = 2f)))
        assertTrue(control.shouldContinueLoading(parameters(14_999_999L, speed = 2f)))
        for (network in listOf(Profile.STANDARD, Profile.METERED)) {
            profile = network
            assertFalse(control.shouldStartPlayback(parameters(2_499_999L)))
            assertTrue(control.shouldStartPlayback(parameters(2_500_000L)))
            assertFalse(control.shouldStartPlayback(parameters(4_999_999L, rebuffering = true)))
            assertTrue(control.shouldStartPlayback(parameters(5_000_000L, rebuffering = true)))
        }
        control.onStopped(player)
        control.onPrepared(player)
        // Media3 每次返回新的按 PlayerId 过滤的外壳；两个外壳读写同一底层分配状态。
        val restartedAllocator = control.getAllocator(player)
        val allocation = restartedAllocator.allocate()
        assertEquals(C.DEFAULT_BUFFER_SEGMENT_SIZE, allocator.totalBytesAllocated)
        restartedAllocator.release(allocation)
        control.onReleased(player)
    }

    /** 本地源把原始加载与起播参数交给 Media3，并在生命周期中维持同一分配器。 */
    @Test
    fun localSourceAndModernLifecycleUseOneDelegate() {
        val delegate = RecordingLoadControl()
        var profile = Profile.LOCAL
        val control = AdaptivePlaybackLoadControl(delegate) { profile }
        val input = parameters(12_000_000L, speed = 1.5f, rebuffering = true)
        control.onPrepared(player)
        control.onTracksSelected(input, TrackGroupArray.EMPTY, emptyArray())
        assertSame(input, delegate.trackParameters)
        assertTrue(control.shouldContinueLoading(input))
        assertSame(input, delegate.loadingParameters)
        assertTrue(control.shouldStartPlayback(input))
        assertSame(input, delegate.startParameters)

        profile = Profile.METERED
        assertTrue(control.shouldContinueLoading(input))
        val metered = checkNotNull(delegate.loadingParameters)
        assertEquals(24_000_000L, metered.bufferedDurationUs)
        assertSame(input.playerId, metered.playerId)
        assertSame(input.timeline, metered.timeline)
        assertSame(input.mediaPeriodId, metered.mediaPeriodId)
        assertEquals(input.playbackPositionUs, metered.playbackPositionUs)
        assertEquals(input.playbackSpeed, metered.playbackSpeed, 0f)
        assertEquals(input.playWhenReady, metered.playWhenReady)
        assertEquals(input.rebuffering, metered.rebuffering)
        assertEquals(input.targetLiveOffsetUs, metered.targetLiveOffsetUs)
        assertEquals(input.lastRebufferRealtimeMs, metered.lastRebufferRealtimeMs)
        assertSame(delegate.allocator, control.getAllocator(player))
        control.onStopped(player)
        control.onReleased(player)
        assertEquals(listOf(player, player, player), delegate.lifecycle)
    }

    private class RecordingLoadControl : LoadControl {
        val lifecycle = mutableListOf<PlayerId>()
        val allocator = DefaultAllocator(true, C.DEFAULT_BUFFER_SEGMENT_SIZE)
        var trackParameters: LoadControl.Parameters? = null
        var loadingParameters: LoadControl.Parameters? = null
        var startParameters: LoadControl.Parameters? = null

        /** 记录 Media3 准备的播放器。 */
        override fun onPrepared(playerId: PlayerId) { lifecycle.add(playerId) }

        /** 记录现代选轨回调参数。 */
        override fun onTracksSelected(
            parameters: LoadControl.Parameters,
            trackGroups: TrackGroupArray,
            trackSelections: Array<out ExoTrackSelection?>,
        ) { trackParameters = parameters }

        /** 记录 Media3 停止的播放器。 */
        override fun onStopped(playerId: PlayerId) { lifecycle.add(playerId) }

        /** 记录 Media3 释放的播放器。 */
        override fun onReleased(playerId: PlayerId) { lifecycle.add(playerId) }

        /** 返回单个分配器，验证包装器原样返回实例。 */
        override fun getAllocator(playerId: PlayerId): Allocator = allocator

        /** 记录续载决策接收到的参数。 */
        override fun shouldContinueLoading(parameters: LoadControl.Parameters): Boolean {
            loadingParameters = parameters
            return true
        }

        /** 记录起播决策接收到的参数。 */
        override fun shouldStartPlayback(parameters: LoadControl.Parameters): Boolean {
            startParameters = parameters
            return true
        }
    }
}
