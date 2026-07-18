package com.focubili.app

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Rational
import android.view.Surface
import android.view.PixelCopy
import android.webkit.CookieManager
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.session.MediaSession
import io.flutter.embedding.engine.renderer.FlutterRenderer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.lang.ref.WeakReference
import java.net.URL
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection

/**
 * 接收 Android 画中画窗口发出的播放/暂停指令。
 *
 * 这里使用广播而不是重新打开 Activity，因此点按小窗按钮时不会主动退出画中画。
 */
class PictureInPicturePlaybackActionReceiver : BroadcastReceiver() {
    /** 将系统小窗操作转交给当前仍存活的原生播放器控制器。 */
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == NativePlaybackController.PICTURE_IN_PICTURE_TOGGLE_ACTION) {
            NativePlaybackController.handlePictureInPicturePlaybackToggle()
        }
    }
}

/**
 * 直接请求公开视频播放数据，并把唯一的 Media3 播放器输出为 Flutter Texture。
 *
 * 播放器同时负责倍速、清晰度切换、本地进度记忆和 Android 系统媒体会话。
 */
@UnstableApi
class NativePlaybackController(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val renderer: FlutterRenderer,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val playbackRequestExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val overlayDataRequestExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val progressPreferences = activity.getSharedPreferences(
        PROGRESS_PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )
    private val cachePreferences = activity.getSharedPreferences(
        CACHE_PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )
    private val audioManager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val cacheDatabaseProvider = StandaloneDatabaseProvider(activity)
    private var mediaCache: SimpleCache? = null
    private var player: ExoPlayer? = null
    private var mediaSession: MediaSession? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var videoSurface: Surface? = null
    private var currentBvid = ""
    private var currentCid = 0L
    private var currentPageNumber = 1
    private var currentTitle = ""
    private var currentPartTitle = ""
    private var currentOwnerName = ""
    private var requestedQuality = DEFAULT_QUALITY
    private var currentQuality = DEFAULT_QUALITY
    private var availableQualities = listOf(
        PlaybackQualityOption(DEFAULT_QUALITY, "高清 720P"),
    )
    private var playbackSpeed = DEFAULT_PLAYBACK_SPEED
    private var pendingStartPositionMs = 0L
    private var restoredPositionMs = 0L
    private var videoAspectRatio = DEFAULT_VIDEO_ASPECT_RATIO
    private var resumeAfterPrepare = true
    private var playbackPrepared = false
    private var resumeWhenForeground = false
    private var playbackDataRefreshCount = 0
    private var playbackSourceAttemptIndex = 0
    private var latestPlaybackSources: PlaybackSources? = null
    private var playbackRequestToken = 0L
    private var lastProgressSaveElapsedMs = 0L
    private var playbackPhase = PHASE_IDLE
    private var playbackMessage: String? = null
    private var isInPictureInPicture = false
    @Volatile
    private var subtitleTrackSession: SubtitleTrackSession? = null

    /** 保存一档可供 Flutter 选择的清晰度编号与名称。 */
    private data class PlaybackQualityOption(
        val id: Int,
        val label: String,
    )

    /** 保存一组已验证的 DASH 主备地址、实际清晰度和媒体请求信息。 */
    private data class PlaybackSources(
        val videoUrls: List<String>,
        val audioUrls: List<String>,
        val videoCodec: String,
        val audioCodec: String,
        val referer: String,
        val actualQuality: Int,
        val qualities: List<PlaybackQualityOption>,
    )

    /** 保存一条选中媒体轨道的编码名称和主备地址，供兼容选择与缓存隔离使用。 */
    private data class SelectedMediaTrack(
        val urls: List<String>,
        val codec: String,
    )

    /** 保存播放失败中可安全展示的原因类型和 HTTP 状态，不含地址、请求头或会话资料。 */
    private data class PlaybackFailureDetails(
        val causeType: String,
        val httpStatusCode: Int?,
    )

    /** 保存当前视频可读取轨道的临时地址；该地址只留在原生内存，绝不经过 Flutter 或磁盘。 */
    private data class SubtitleTrackSession(
        val bvid: String,
        val cid: Long,
        val readableTrackUrls: Map<String, String>,
    )

    /** 保存一条可展示但不含临时资源地址的字幕轨道元数据。 */
    private data class SubtitleTrackOption(
        val id: String,
        val language: String,
        val label: String,
        val isLocked: Boolean,
    )

    /** 保存已从一段 Protobuf 数据安全解析出的普通弹幕展示字段。 */
    private data class DanmakuElement(
        val progressMs: Long,
        val content: String,
        val color: Int,
        val mode: Int,
    )

    /** 表示播放数据服务返回了可向用户说明的预期错误。 */
    private class PlaybackSourceException(message: String) : Exception(message)

    /** 表示缓存管理请求中可安全展示给 Flutter 页面的预期错误。 */
    private class CacheOperationException(
        val errorCode: String,
        message: String,
    ) : Exception(message)

    /** 表示字幕接口或内容格式中可安全展示给 Flutter 页面的预期错误。 */
    private class SubtitleOperationException(
        val errorCode: String,
        message: String,
    ) : Exception(message)

    /** 表示弹幕数据接口或 Protobuf 内容中可安全展示给 Flutter 页面的预期错误。 */
    private class DanmakuOperationException(
        val errorCode: String,
        message: String,
    ) : Exception(message)

    /** 每半秒保存必要进度并向 Flutter 发送播放器状态。 */
    private val stateTicker = object : Runnable {
        /** 在播放器仍存在时保存进度、发送状态并安排下一次刷新。 */
        override fun run() {
            if (player != null) {
                saveCurrentPlaybackProgress(force = false)
                emitPlaybackState()
                mainHandler.postDelayed(this, STATE_TICK_INTERVAL_MS)
            }
        }
    }

    /** 创建控制器时注册方法通道，使 Flutter 可以立即初始化播放器。 */
    init {
        channel.setMethodCallHandler(this)
    }

    /** 接收 Flutter 的打开视频、播放控制、倍速、清晰度和资源释放命令。 */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                ensurePlayer()
                result.success(mapOf("textureId" to ensureTexture()))
            }
            "open" -> {
                val bvid = call.argument<String>("bvid")?.trim().orEmpty()
                val cid = call.argument<Number>("cid")?.toLong()
                val pageNumber = call.argument<Number>("pageNumber")?.toInt() ?: 1
                val quality = call.argument<Number>("quality")?.toInt() ?: DEFAULT_QUALITY
                if (buildVideoPageUrl(bvid) == null) {
                    result.error("invalid_bvid", "请输入有效的 BV 号。", null)
                } else if (cid == null || cid <= 0L) {
                    result.error("invalid_cid", "该视频没有可播放的分P编号。", null)
                } else if (pageNumber <= 0) {
                    result.error("invalid_page", "请选择有效的分P。", null)
                } else if (quality <= 0) {
                    result.error("invalid_quality", "请选择有效的清晰度。", null)
                } else {
                    openVideo(
                        bvid = bvid,
                        cid = cid,
                        pageNumber = pageNumber,
                        quality = quality,
                        title = call.argument<String>("title").orEmpty(),
                        partTitle = call.argument<String>("partTitle").orEmpty(),
                        ownerName = call.argument<String>("ownerName").orEmpty(),
                    )
                    result.success(null)
                }
            }
            "play" -> {
                resumeAfterPrepare = true
                player?.play()
                result.success(null)
            }
            "pause" -> {
                resumeAfterPrepare = false
                player?.pause()
                result.success(null)
            }
            "seekBy" -> {
                val offset = call.argument<Number>("offsetMs")?.toLong() ?: 0L
                seekBy(offset)
                result.success(null)
            }
            "seekTo" -> {
                val position = call.argument<Number>("positionMs")?.toLong() ?: 0L
                seekToPosition(position)
                result.success(null)
            }
            "setSpeed" -> {
                val speed = call.argument<Number>("speed")?.toFloat()
                if (speed == null || !speed.isFinite() ||
                    speed < MIN_PLAYBACK_SPEED || speed > MAX_PLAYBACK_SPEED
                ) {
                    result.error("invalid_speed", "倍速必须在 0.5 到 2.0 之间。", null)
                } else {
                    setPlaybackSpeed(speed)
                    result.success(null)
                }
            }
            "selectQuality" -> {
                val quality = call.argument<Number>("quality")?.toInt()
                if (quality == null || quality <= 0) {
                    result.error("invalid_quality", "请选择有效的清晰度。", null)
                } else {
                    switchQuality(quality)
                    result.success(null)
                }
            }
            "getSavedPlaybackState" -> {
                val bvid = call.argument<String>("bvid")?.trim().orEmpty()
                result.success(loadSavedVideoState(bvid))
            }
            "getSystemPlaybackLevels" -> {
                result.success(readSystemPlaybackLevels())
            }
            "setScreenBrightness" -> {
                val value = call.argument<Number>("value")?.toFloat() ?: 0.5f
                setScreenBrightness(value)
                result.success(null)
            }
            "setMediaVolume" -> {
                val value = call.argument<Number>("value")?.toFloat() ?: 0.5f
                setMediaVolume(value)
                result.success(null)
            }
            "enterPictureInPicture" -> {
                val aspectRatio = call.argument<Number>("aspectRatio")?.toDouble()
                    ?: videoAspectRatio.toDouble()
                enterPictureInPicture(aspectRatio, result)
            }
            "captureCurrentFrame" -> {
                captureCurrentVideoFrame(result)
            }
            "getMediaCacheStatus" -> {
                handleMediaCacheOperation(result, ::readMediaCacheStatus)
            }
            "setMediaCacheCapacity" -> {
                val capacityBytes = call.argument<Number>("capacityBytes")?.toLong()
                if (capacityBytes == null || !isSupportedMediaCacheCapacity(capacityBytes)) {
                    result.error(
                        "invalid_cache_capacity",
                        "缓存上限只能设为 128MB、256MB、512MB、1GB 或 2GB。",
                        null,
                    )
                } else {
                    handleMediaCacheOperation(result) {
                        setMediaCacheCapacity(capacityBytes)
                    }
                }
            }
            "clearMediaCache" -> {
                handleMediaCacheOperation(result, ::clearMediaCache)
            }
            "loadSubtitleTracks" -> {
                val bvid = call.argument<String>("bvid")?.trim().orEmpty()
                val cid = call.argument<Number>("cid")?.toLong()
                if (buildVideoPageUrl(bvid) == null || cid == null || cid <= 0L) {
                    result.error("invalid_subtitle_request", "字幕请求参数无效。", null)
                } else {
                    requestSubtitleTracks(bvid, cid, result)
                }
            }
            "loadSubtitleCues" -> {
                val bvid = call.argument<String>("bvid")?.trim().orEmpty()
                val cid = call.argument<Number>("cid")?.toLong()
                val trackId = call.argument<String>("trackId")?.trim().orEmpty()
                if (buildVideoPageUrl(bvid) == null || cid == null || cid <= 0L || trackId.isEmpty()) {
                    result.error("invalid_subtitle_request", "字幕请求参数无效。", null)
                } else {
                    requestSubtitleCues(bvid, cid, trackId, result)
                }
            }
            "loadDanmakuSegment" -> {
                val bvid = call.argument<String>("bvid")?.trim().orEmpty()
                val cid = call.argument<Number>("cid")?.toLong()
                val segmentIndex = call.argument<Number>("segmentIndex")?.toInt()
                if (buildVideoPageUrl(bvid) == null || cid == null || cid <= 0L ||
                    segmentIndex == null || segmentIndex !in 1..MAX_DANMAKU_SEGMENT_INDEX
                ) {
                    result.error("invalid_danmaku_request", "弹幕请求参数无效。", null)
                } else {
                    requestDanmakuSegment(bvid, cid, segmentIndex, result)
                }
            }
            "dispose" -> {
                releasePlaybackResources()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** App 返回前台时按离开前的状态恢复唯一的 Media3 播放器。 */
    fun onHostResume() {
        if (resumeWhenForeground) {
            resumeAfterPrepare = true
            player?.play()
        }
    }

    /** App 进入后台时暂停播放，同时保留返回前台时是否需要恢复的信息。 */
    fun onHostPause() {
        val nativePlayer = player
        resumeWhenForeground = nativePlayer?.playWhenReady == true || resumeAfterPrepare
        resumeAfterPrepare = false
        nativePlayer?.pause()
        saveCurrentPlaybackProgress(force = true)
    }

    /** 宿主 Activity 销毁时释放媒体会话、播放器、纹理和后台网络任务。 */
    fun onHostDestroy() {
        releasePlaybackResources()
        releaseMediaCache()
        playbackRequestExecutor.shutdownNow()
        overlayDataRequestExecutor.shutdownNow()
        channel.setMethodCallHandler(null)
    }

    /** Android 画中画状态变化时同步给 Flutter，并刷新小窗中的播放/暂停操作。 */
    fun onPictureInPictureModeChanged(inPictureInPicture: Boolean) {
        isInPictureInPicture = inPictureInPicture
        if (inPictureInPicture) {
            refreshPictureInPictureParams()
        } else {
            unregisterPictureInPictureActionHandler()
        }
        emitPlaybackState()
    }

    /** 使用当前视频比例请求 Android 8.0 及以上系统画中画能力。 */
    private fun enterPictureInPicture(
        requestedAspectRatio: Double,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("pip_unsupported", "当前 Android 版本不支持画中画。", null)
            return
        }
        if (!playbackPrepared || player == null) {
            result.error("pip_not_ready", "视频准备完成后才能进入画中画。", null)
            return
        }
        registerPictureInPictureActionHandler()
        val entered = runCatching {
            activity.enterPictureInPictureMode(
                buildPictureInPictureParams(requestedAspectRatio),
            )
        }.getOrDefault(false)
        if (!entered) {
            unregisterPictureInPictureActionHandler()
        }
        result.success(entered)
    }

    /**
     * 构造画中画参数，并附上当前播放状态匹配的系统播放/暂停按钮。
     *
     * Android 8.0 起支持 `RemoteAction`；Android 12 起额外启用无缝缩放，避免尺寸切换闪烁。
     */
    private fun buildPictureInPictureParams(requestedAspectRatio: Double): PictureInPictureParams {
        val safeAspectRatio = sanitizePictureInPictureAspectRatio(requestedAspectRatio)
        val paramsBuilder = PictureInPictureParams.Builder()
            .setAspectRatio(
                Rational(
                    (safeAspectRatio * PICTURE_IN_PICTURE_RATIO_BASE).toInt(),
                    PICTURE_IN_PICTURE_RATIO_BASE,
                ),
            )
            .setActions(listOf(createPictureInPicturePlaybackAction()))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            paramsBuilder.setSeamlessResizeEnabled(true)
        }
        return paramsBuilder.build()
    }

    /** 将调用方传入的画中画比例限制在 Android 支持的安全范围内。 */
    private fun sanitizePictureInPictureAspectRatio(requestedAspectRatio: Double): Double {
        return requestedAspectRatio
            .takeIf { ratio -> ratio.isFinite() && ratio > 0.0 }
            ?.coerceIn(MIN_PICTURE_IN_PICTURE_ASPECT, MAX_PICTURE_IN_PICTURE_ASPECT)
            ?: DEFAULT_VIDEO_ASPECT_RATIO.toDouble()
    }

    /**
     * 创建与当前 `playWhenReady` 状态一致的画中画播放/暂停按钮。
     *
     * 使用不可变 `PendingIntent`，让 Android 12 及以上系统在保留安全性的前提下执行应用内广播。
     */
    private fun createPictureInPicturePlaybackAction(): RemoteAction {
        val shouldPause = player?.playWhenReady == true &&
            player?.playbackState != Player.STATE_ENDED
        val iconResource = if (shouldPause) {
            android.R.drawable.ic_media_pause
        } else {
            android.R.drawable.ic_media_play
        }
        val label = if (shouldPause) "暂停" else "播放"
        val toggleIntent = Intent(activity, PictureInPicturePlaybackActionReceiver::class.java)
            .setAction(PICTURE_IN_PICTURE_TOGGLE_ACTION)
            .setPackage(activity.packageName)
        val pendingIntent = PendingIntent.getBroadcast(
            activity,
            PICTURE_IN_PICTURE_TOGGLE_REQUEST_CODE,
            toggleIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return RemoteAction(
            Icon.createWithResource(activity, iconResource),
            label,
            "${label}当前视频",
            pendingIntent,
        )
    }

    /**
     * 在播放状态变化时更新系统画中画按钮的图标和文字。
     *
     * 更新参数不会把小窗展开为普通 Activity，因此不会主动离开画中画。
     */
    private fun refreshPictureInPictureParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            !isInPictureInPicture ||
            !playbackPrepared
        ) {
            return
        }
        runCatching {
            activity.setPictureInPictureParams(
                buildPictureInPictureParams(videoAspectRatio.toDouble()),
            )
        }
    }

    /** 记录当前控制器的弱引用，使系统广播只操作仍存活的播放器而不泄漏 Activity。 */
    private fun registerPictureInPictureActionHandler() {
        activePictureInPictureController = WeakReference(this)
    }

    /** 在播放资源释放或进入画中画失败时移除自身引用，避免旧小窗按钮操作已销毁播放器。 */
    private fun unregisterPictureInPictureActionHandler() {
        if (activePictureInPictureController?.get() === this) {
            activePictureInPictureController = null
        }
    }

    /**
     * 响应画中画按钮并切换 Media3 播放状态。
     *
     * 该方法只修改播放器，不启动 Activity，因此不会主动退出画中画。
     */
    private fun togglePlaybackFromPictureInPicture() {
        if (!isInPictureInPicture || !playbackPrepared) {
            return
        }
        val nativePlayer = player ?: return
        if (nativePlayer.playWhenReady) {
            resumeAfterPrepare = false
            nativePlayer.pause()
        } else {
            resumeAfterPrepare = true
            nativePlayer.play()
        }
        refreshPictureInPictureParams()
        emitPlaybackState()
    }

    /** 创建 Media3 播放器、音频焦点和系统媒体会话，并注册状态监听。 */
    private fun ensurePlayer() {
        if (player != null) {
            return
        }
        val nativePlayer = ExoPlayer.Builder(activity).build()
        nativePlayer.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            true,
        )
        nativePlayer.setHandleAudioBecomingNoisy(true)
        nativePlayer.playbackParameters = PlaybackParameters(playbackSpeed)
        nativePlayer.addListener(object : Player.Listener {
            /** 播放或暂停变化时把最新状态同步给 Flutter。 */
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (playbackPrepared && playbackPhase != PHASE_ERROR) {
                    playbackPhase = PHASE_READY
                    playbackMessage = null
                }
                updateKeepScreenOn(isPlaying)
                refreshPictureInPictureParams()
                emitPlaybackState()
            }

            /** 缓冲、就绪和播完状态变化时更新提示与播放记忆。 */
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        playbackPhase = PHASE_LOADING
                        playbackMessage = "正在缓冲视频…"
                    }
                    Player.STATE_READY -> {
                        playbackPrepared = true
                        playbackDataRefreshCount = 0
                        playbackPhase = PHASE_READY
                        playbackMessage = null
                    }
                    Player.STATE_ENDED -> {
                        playbackPhase = PHASE_ENDED
                        playbackMessage = "播放结束"
                        clearSavedPlaybackProgress(currentBvid, currentCid)
                    }
                }
                refreshPictureInPictureParams()
                emitPlaybackState()
            }

            /** 倍速由 App 或系统控制端改变时同步最新数值。 */
            override fun onPlaybackParametersChanged(playbackParameters: PlaybackParameters) {
                playbackSpeed = playbackParameters.speed
                emitPlaybackState()
            }

            /** 视频真实尺寸变化时计算宽高比，供 Flutter 普通页铺满宽度及全屏居中适配。 */
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    videoAspectRatio =
                        videoSize.width.toFloat() * videoSize.pixelWidthHeightRatio /
                        videoSize.height.toFloat()
                    emitPlaybackState()
                }
            }

            /** 网络或播放地址失败时保留进度，依次尝试备用线路和有限次数的数据刷新。 */
            override fun onPlayerError(error: PlaybackException) {
                retryPlaybackAfterError(nativePlayer, error)
            }
        })
        player = nativePlayer
        mediaSession = MediaSession.Builder(activity, nativePlayer).build()
        nativePlayer.setVideoSurface(videoSurface)
        mainHandler.removeCallbacks(stateTicker)
        mainHandler.post(stateTicker)
    }

    /** 播放失败后先轮换备用 CDN，再有限次数刷新播放数据，避免长视频偶发断流直接报错。 */
    private fun retryPlaybackAfterError(
        nativePlayer: ExoPlayer,
        error: PlaybackException,
    ) {
        val failureDetails = inspectPlaybackFailure(error)
        if (currentBvid.isEmpty() || currentCid <= 0L) {
            reportError(
                buildFinalPlaybackErrorMessage(
                    prefix = "原生播放器无法播放该视频",
                    error = error,
                    sources = latestPlaybackSources,
                    failureDetails = failureDetails,
                ),
            )
            return
        }
        pendingStartPositionMs = nativePlayer.currentPosition.coerceAtLeast(0L)
        resumeAfterPrepare = nativePlayer.playWhenReady || resumeAfterPrepare
        playbackPrepared = false
        val sources = latestPlaybackSources
        val candidateCount = sources?.let(::playbackCandidateCount) ?: 0
        val nextCandidateIndex = playbackSourceAttemptIndex + 1
        val shouldRefreshPlayurl = shouldRefreshPlayurlImmediately(failureDetails)
        if (!shouldRefreshPlayurl && sources != null && nextCandidateIndex < candidateCount) {
            playbackSourceAttemptIndex = nextCandidateIndex
            playbackPhase = PHASE_LOADING
            playbackMessage = "当前线路不稳定，正在切换备用线路…"
            emitPlaybackState()
            mainHandler.postDelayed(
                {
                    if (player === nativePlayer && latestPlaybackSources === sources) {
                        prepareMediaSources(sources)
                    }
                },
                BACKUP_SOURCE_RETRY_DELAY_MS,
            )
            return
        }
        if (playbackDataRefreshCount < MAX_PLAYBACK_DATA_REFRESH_COUNT) {
            playbackDataRefreshCount += 1
            playbackSourceAttemptIndex = 0
            latestPlaybackSources = null
            playbackPhase = PHASE_LOADING
            playbackMessage = if (shouldRefreshPlayurl) {
                "播放地址已失效，正在刷新播放数据…"
            } else {
                "播放线路已失效，正在刷新播放数据…"
            }
            emitPlaybackState()
            requestPlaybackSources(currentBvid, currentCid, requestedQuality)
            return
        }
        reportError(
            buildFinalPlaybackErrorMessage(
                prefix = "原生播放器多次重试后仍无法播放",
                error = error,
                sources = sources,
                failureDetails = failureDetails,
            ),
        )
    }

    /**
     * 从有限长度的异常 cause 链中提取适合用户诊断的类型和 HTTP 状态。
     *
     * 只读取异常类别与状态码，绝不读取异常 message、响应体、URL、请求头或 Cookie。
     */
    private fun inspectPlaybackFailure(error: PlaybackException): PlaybackFailureDetails {
        var current: Throwable? = error.cause
        var deepestCause: Throwable? = current
        var invalidResponse: HttpDataSource.InvalidResponseCodeException? = null
        repeat(MAX_PLAYBACK_ERROR_CAUSE_DEPTH) {
            val cause = current ?: return@repeat
            if (cause is HttpDataSource.InvalidResponseCodeException && invalidResponse == null) {
                invalidResponse = cause
            }
            deepestCause = cause
            current = cause.cause?.takeIf { nestedCause -> nestedCause !== cause }
        }
        val diagnosticCause = invalidResponse ?: deepestCause
        return PlaybackFailureDetails(
            causeType = describePlaybackCauseType(diagnosticCause),
            httpStatusCode = invalidResponse?.responseCode,
        )
    }

    /** 把底层异常类别转为中文且脱敏的名称，避免异常文本把敏感请求资料带到页面。 */
    private fun describePlaybackCauseType(cause: Throwable?): String {
        return when (cause) {
            is HttpDataSource.InvalidResponseCodeException -> "HTTP 响应状态异常（InvalidResponseCodeException）"
            is java.net.SocketTimeoutException -> "网络读取超时（SocketTimeoutException）"
            is java.net.ConnectException -> "网络连接异常（ConnectException）"
            is java.io.EOFException -> "网络数据提前结束（EOFException）"
            is java.io.IOException -> "网络输入输出异常（IOException）"
            null -> "未提供底层原因"
            else -> "播放器内部异常（${cause.javaClass.simpleName.ifBlank { "Unknown" }}）"
        }
    }

    /** 判断明确过期或被服务器拒绝的媒体地址是否应跳过候选轮换并立即刷新 playurl。 */
    private fun shouldRefreshPlayurlImmediately(failureDetails: PlaybackFailureDetails): Boolean {
        return when (failureDetails.httpStatusCode) {
            HTTP_STATUS_FORBIDDEN,
            HTTP_STATUS_NOT_FOUND,
            HTTP_STATUS_GONE,
            -> true
            else -> false
        }
    }

    /** 构造最终错误提示，只展示脱敏原因、可诊断状态码和当前音视频候选序号。 */
    private fun buildFinalPlaybackErrorMessage(
        prefix: String,
        error: PlaybackException,
        sources: PlaybackSources?,
        failureDetails: PlaybackFailureDetails,
    ): String {
        val httpStatusDescription = failureDetails.httpStatusCode?.let { statusCode ->
            "；HTTP 状态码：$statusCode"
        }.orEmpty()
        return "$prefix：${error.errorCodeName}（诊断：底层原因类型：${failureDetails.causeType}" +
            httpStatusDescription +
            "；候选索引：${describePlaybackCandidateIndexes(sources)}）"
    }

    /** 返回当前实际选中的视频和音频候选序号，不显示任何媒体地址。 */
    private fun describePlaybackCandidateIndexes(sources: PlaybackSources?): String {
        if (sources == null) {
            return "视频未知，音频未知"
        }
        return "视频 ${describeCurrentCandidateIndex(sources.videoUrls)}，" +
            "音频 ${describeCurrentCandidateIndex(sources.audioUrls)}"
    }

    /** 按 `mediaUrlAt` 的回退规则计算当前真实使用的候选序号，空音轨明确标记为无。 */
    private fun describeCurrentCandidateIndex(urls: List<String>): String {
        if (urls.isEmpty()) {
            return "无"
        }
        val actualIndex = if (playbackSourceAttemptIndex in urls.indices) {
            playbackSourceAttemptIndex
        } else {
            0
        }
        return "${actualIndex + 1}/${urls.size}"
    }

    /** 返回本次音视频主备地址中需要尝试的最大线路数量。 */
    private fun playbackCandidateCount(sources: PlaybackSources): Int {
        return maxOf(sources.videoUrls.size, sources.audioUrls.size.coerceAtLeast(1))
    }

    /** 创建 Flutter 可显示的 SurfaceTexture，并把它作为 Media3 的视频输出表面。 */
    private fun ensureTexture(): Long {
        textureEntry?.let { return it.id() }
        val entry = renderer.createSurfaceTexture()
        entry.surfaceTexture().setDefaultBufferSize(DEFAULT_TEXTURE_WIDTH, DEFAULT_TEXTURE_HEIGHT)
        textureEntry = entry
        videoSurface = Surface(entry.surfaceTexture())
        player?.setVideoSurface(videoSurface)
        return entry.id()
    }

    /** 使用 PixelCopy 把当前视频 Surface 保存为应用私有 JPEG，供时间点笔记插入画面。 */
    private fun captureCurrentVideoFrame(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.error("frame_capture_unsupported", "当前 Android 版本不支持截取视频画面。", null)
            return
        }
        val surface = videoSurface
        val videoSize = player?.videoSize
        if (surface == null || !surface.isValid || videoSize == null ||
            videoSize.width <= 0 || videoSize.height <= 0
        ) {
            result.error("frame_capture_unavailable", "视频画面还没有准备好，请稍后再试。", null)
            return
        }
        val maximumWidth = 1280
        val scale = minOf(1.0, maximumWidth.toDouble() / videoSize.width.toDouble())
        val width = maxOf(2, (videoSize.width * scale).toInt())
        val height = maxOf(2, (videoSize.height * scale).toInt())
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        PixelCopy.request(
            surface,
            bitmap,
            { copyResult ->
                if (copyResult != PixelCopy.SUCCESS) {
                    bitmap.recycle()
                    result.error(
                        "frame_capture_failed",
                        "无法读取当前视频画面，请继续播放后再试。",
                        copyResult,
                    )
                    return@request
                }
                playbackRequestExecutor.execute {
                    try {
                        val directory = File(activity.filesDir, "video_note_frames")
                        if (!directory.exists() && !directory.mkdirs()) {
                            throw IllegalStateException("无法创建笔记画面目录。")
                        }
                        val safeBvid = currentBvid.replace(Regex("[^0-9A-Za-z]"), "_")
                        val output = File(
                            directory,
                            "${safeBvid}_${System.currentTimeMillis()}.jpg",
                        )
                        FileOutputStream(output).use { stream ->
                            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream)) {
                                throw IllegalStateException("无法压缩当前视频画面。")
                            }
                        }
                        bitmap.recycle()
                        mainHandler.post { result.success(output.absolutePath) }
                    } catch (error: Throwable) {
                        bitmap.recycle()
                        mainHandler.post {
                            result.error(
                                "frame_capture_failed",
                                error.message ?: "保存当前视频画面失败。",
                                null,
                            )
                        }
                    }
                }
            },
            mainHandler,
        )
    }

    /** 保存旧分P、重置播放器，并请求新分P所选清晰度的 DASH 地址。 */
    private fun openVideo(
        bvid: String,
        cid: Long,
        pageNumber: Int,
        quality: Int,
        title: String,
        partTitle: String,
        ownerName: String,
    ) {
        ensurePlayer()
        ensureTexture()
        saveCurrentPlaybackProgress(force = true)
        invalidatePlaybackRequests()
        clearSubtitleTrackSession()
        player?.stop()
        player?.clearMediaItems()
        currentBvid = bvid
        currentCid = cid
        currentPageNumber = pageNumber
        currentTitle = title
        currentPartTitle = partTitle
        currentOwnerName = ownerName
        requestedQuality = quality
        currentQuality = quality
        pendingStartPositionMs = loadSavedPlaybackPosition(bvid, cid)
        restoredPositionMs = pendingStartPositionMs
        saveCurrentPartSelection()
        resumeAfterPrepare = true
        playbackPrepared = false
        resumeWhenForeground = false
        playbackDataRefreshCount = 0
        playbackSourceAttemptIndex = 0
        latestPlaybackSources = null
        playbackPhase = PHASE_LOADING
        playbackMessage = if (pendingStartPositionMs > 0L) {
            "正在恢复上次播放位置…"
        } else {
            "正在请求播放数据…"
        }
        emitPlaybackState()
        requestPlaybackSources(bvid, cid, quality)
    }

    /** 保留当前位置与播放状态，再重新请求指定清晰度。 */
    private fun switchQuality(quality: Int) {
        if (currentBvid.isEmpty() || currentCid <= 0L) {
            reportError("当前没有可切换清晰度的视频。")
            return
        }
        if (playbackPrepared && quality == currentQuality) {
            return
        }
        val nativePlayer = player ?: return
        val shouldResume = nativePlayer.playWhenReady
        pendingStartPositionMs = nativePlayer.currentPosition.coerceAtLeast(0L)
        nativePlayer.pause()
        resumeAfterPrepare = shouldResume
        requestedQuality = quality
        currentQuality = quality
        playbackPrepared = false
        playbackDataRefreshCount = 0
        playbackSourceAttemptIndex = 0
        latestPlaybackSources = null
        playbackPhase = PHASE_LOADING
        playbackMessage = "正在切换清晰度…"
        emitPlaybackState()
        requestPlaybackSources(currentBvid, currentCid, quality)
    }

    /** 将 Media3 切换为指定倍速，并立即同步给 Flutter 与系统媒体会话。 */
    private fun setPlaybackSpeed(speed: Float) {
        playbackSpeed = speed
        player?.playbackParameters = PlaybackParameters(speed)
        emitPlaybackState()
    }

    /** 在单线程后台请求播放数据，并只让最新请求更新当前视频。 */
    private fun requestPlaybackSources(bvid: String, cid: Long, quality: Int) {
        val requestToken = createPlaybackRequestToken()
        playbackRequestExecutor.execute {
            val sourceResult = runCatching {
                loadPlaybackSources(bvid, cid, quality)
            }
            mainHandler.post {
                if (!isCurrentPlaybackRequest(requestToken, bvid, cid, quality)) {
                    return@post
                }
                sourceResult.onSuccess(::prepareMediaSources).onFailure { error ->
                    reportError(describePlaybackFetchFailure(error))
                }
            }
        }
    }

    /** 请求播放 JSON，并挑选目标清晰度的 DASH 视频轨和最高质量音频轨。 */
    private fun loadPlaybackSources(
        bvid: String,
        cid: Long,
        quality: Int,
    ): PlaybackSources {
        val responseText = requestPlaybackInfoJson(bvid, cid, quality)
        val root = JSONObject(responseText)
        val code = root.optInt("code", -1)
        if (code != 0) {
            val serverMessage = root.optString("message")
            val readableMessage = if (serverMessage.isBlank() || serverMessage == "0") {
                "播放数据服务拒绝了本次请求（错误码：$code）。"
            } else {
                "无法取得播放数据：$serverMessage（错误码：$code）。"
            }
            throw PlaybackSourceException(readableMessage)
        }
        val data = root.optJSONObject("data")
            ?: throw PlaybackSourceException("播放数据服务没有返回视频信息。")
        val dash = data.optJSONObject("dash")
            ?: throw PlaybackSourceException("该视频没有可用的 DASH 播放数据。")
        val actualQuality = data.optInt("quality", quality).takeIf { it > 0 } ?: quality
        val videoTrack = selectMediaTrack(dash.optJSONArray("video"), actualQuality)
        val audioTrack = selectMediaTrack(dash.optJSONArray("audio"))
        if (videoTrack.urls.isEmpty()) {
            throw PlaybackSourceException("播放数据没有返回安全的视频地址。")
        }
        val referer = buildVideoPageUrl(bvid)
            ?: throw PlaybackSourceException("无法生成视频页面地址。")
        return PlaybackSources(
            videoUrls = videoTrack.urls,
            audioUrls = audioTrack.urls,
            videoCodec = videoTrack.codec,
            audioCodec = audioTrack.codec,
            referer = referer,
            actualQuality = actualQuality,
            qualities = parseQualityOptions(data, dash),
        )
    }

    /** 使用 HTTPS 请求指定分P和清晰度的播放数据。 */
    private fun requestPlaybackInfoJson(
        bvid: String,
        cid: Long,
        quality: Int,
    ): String {
        val endpoint = Uri.Builder()
            .scheme("https")
            .authority(PLAYBACK_API_HOST)
            .appendPath("x")
            .appendPath("player")
            .appendPath("playurl")
            .appendQueryParameter("bvid", bvid)
            .appendQueryParameter("cid", cid.toString())
            .appendQueryParameter("qn", quality.toString())
            .appendQueryParameter("fnval", DASH_FEATURE_FLAG.toString())
            .appendQueryParameter("fourk", "1")
            .build()
        val connection = URL(endpoint.toString()).openConnection() as HttpsURLConnection
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = NETWORK_TIMEOUT_MS
            connection.readTimeout = NETWORK_TIMEOUT_MS
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Referer", buildVideoPageUrl(bvid).orEmpty())
            connection.setRequestProperty("User-Agent", DESKTOP_USER_AGENT)
            readBilibiliCookieHeader().takeIf { cookie -> cookie.isNotBlank() }?.let { cookie ->
                connection.setRequestProperty("Cookie", cookie)
            }
            val statusCode = connection.responseCode
            val responseBody = (if (statusCode in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream
            })?.bufferedReader()?.use { reader -> reader.readText() }.orEmpty()
            if (statusCode !in 200..299) {
                throw PlaybackSourceException("播放数据服务暂时不可用（HTTP $statusCode）。")
            }
            if (responseBody.isBlank()) {
                throw PlaybackSourceException("播放数据服务返回了空内容。")
            }
            return responseBody
        } finally {
            connection.disconnect()
        }
    }

    /**
     * 在独立后台线程读取字幕轨道，避免字幕网络慢时阻塞视频播放数据请求。
     *
     * 成功时只回传轨道编号、语言、名称和锁定状态；临时字幕地址始终留在原生内存。
     */
    private fun requestSubtitleTracks(
        bvid: String,
        cid: Long,
        result: MethodChannel.Result,
    ) {
        runCatching {
            overlayDataRequestExecutor.execute {
                val trackResult = runCatching { loadSubtitleTracks(bvid, cid) }
                mainHandler.post {
                    trackResult.onSuccess(result::success).onFailure { error ->
                        reportSubtitleOperationFailure(result, error)
                    }
                }
            }
        }.onFailure {
            result.error("subtitle_unavailable", "字幕暂时无法读取，请稍后重试。", null)
        }
    }

    /** 在独立后台线程读取一条已经由当前视频元数据确认的字幕轨道内容。 */
    private fun requestSubtitleCues(
        bvid: String,
        cid: Long,
        trackId: String,
        result: MethodChannel.Result,
    ) {
        runCatching {
            overlayDataRequestExecutor.execute {
                val cueResult = runCatching { loadSubtitleCues(bvid, cid, trackId) }
                mainHandler.post {
                    cueResult.onSuccess(result::success).onFailure { error ->
                        reportSubtitleOperationFailure(result, error)
                    }
                }
            }
        }.onFailure {
            result.error("subtitle_unavailable", "字幕暂时无法读取，请稍后重试。", null)
        }
    }

    /**
     * 请求固定的 B 站播放器字幕元数据，并把可读轨道的临时地址保留在原生会话内。
     *
     * `is_lock=true` 的轨道只作为锁定状态回传，绝不会尝试读取内容或绕过权限。
     */
    private fun loadSubtitleTracks(bvid: String, cid: Long): Map<String, Any> {
        val root = parseSubtitleJson(requestSubtitleMetadataJson(bvid, cid))
        val code = root.optInt("code", -1)
        if (code == SUBTITLE_LOGIN_REQUIRED_CODE) {
            clearSubtitleTrackSession()
            return subtitleTrackResult(
                status = SUBTITLE_STATUS_LOGIN_REQUIRED,
                message = "登录后可尝试读取字幕。",
            )
        }
        if (code != 0) {
            throw SubtitleOperationException(
                "subtitle_service_error",
                "字幕服务暂时不可用（错误码：$code）。",
            )
        }
        val data = root.optJSONObject("data")
            ?: throw SubtitleOperationException("subtitle_invalid_data", "字幕数据格式不正确。")
        val subtitle = data.optJSONObject("subtitle")
        val rawTracks = subtitle?.optJSONArray("subtitles")
        val tracks = mutableListOf<SubtitleTrackOption>()
        val readableTrackUrls = linkedMapOf<String, String>()
        if (rawTracks != null) {
            for (index in 0 until rawTracks.length()) {
                if (tracks.size >= MAX_SUBTITLE_TRACKS) {
                    break
                }
                val rawTrack = rawTracks.optJSONObject(index) ?: continue
                val trackId = readSubtitleTrackId(rawTrack) ?: continue
                if (tracks.any { track -> track.id == trackId }) {
                    continue
                }
                val language = rawTrack.optString("lan").trim()
                val label = limitSubtitleText(
                    rawTrack.optString("lan_doc").trim().ifBlank {
                        language.ifBlank { "未知语言" }
                    },
                    MAX_SUBTITLE_LABEL_CODE_POINTS,
                )
                val serviceLocked = rawTrack.optBoolean("is_lock", false)
                val subtitleUrl = if (serviceLocked) {
                    null
                } else {
                    normalizeSafeSubtitleUrl(rawTrack.optString("subtitle_url"))
                }
                val isLocked = serviceLocked || subtitleUrl == null
                tracks.add(
                    SubtitleTrackOption(
                        id = trackId,
                        language = language,
                        label = label,
                        isLocked = isLocked,
                    ),
                )
                if (subtitleUrl != null) {
                    readableTrackUrls[trackId] = subtitleUrl
                }
            }
        }
        subtitleTrackSession = SubtitleTrackSession(
            bvid = bvid,
            cid = cid,
            readableTrackUrls = readableTrackUrls.toMap(),
        )
        if (readableTrackUrls.isNotEmpty()) {
            return subtitleTrackResult(
                status = SUBTITLE_STATUS_AVAILABLE,
                tracks = tracks,
            )
        }
        val needsLogin = data.optBoolean("need_login_subtitle", false)
        return when {
            needsLogin -> subtitleTrackResult(
                status = SUBTITLE_STATUS_LOGIN_REQUIRED,
                message = "登录后可尝试读取字幕。",
                tracks = tracks,
            )
            tracks.isNotEmpty() -> subtitleTrackResult(
                status = SUBTITLE_STATUS_LOCKED,
                message = "此视频的字幕当前不可用。",
                tracks = tracks,
            )
            else -> subtitleTrackResult(
                status = SUBTITLE_STATUS_NONE,
                message = "此视频没有可用字幕。",
            )
        }
    }

    /**
     * 读取指定轨道的 JSON 字幕条目，并按数量、文本长度和时间范围进行原生侧限制。
     *
     * Flutter 只收到 `fromMs`、`toMs` 和 `content`，不会收到临时 CDN 地址或会话信息。
     */
    private fun loadSubtitleCues(
        bvid: String,
        cid: Long,
        trackId: String,
    ): Map<String, Any> {
        val session = subtitleTrackSession
        if (session == null || session.bvid != bvid || session.cid != cid) {
            throw SubtitleOperationException(
                "subtitle_track_not_loaded",
                "请先读取当前视频的字幕轨道。",
            )
        }
        val subtitleUrl = session.readableTrackUrls[trackId]
            ?: throw SubtitleOperationException("subtitle_locked", "此字幕当前不可用。")
        val root = parseSubtitleJson(requestSubtitleDocumentJson(subtitleUrl, bvid))
        val rawCues = root.optJSONArray("body")
        val cues = mutableListOf<Map<String, Any>>()
        if (rawCues != null) {
            for (index in 0 until rawCues.length()) {
                if (cues.size >= MAX_SUBTITLE_CUES) {
                    break
                }
                val rawCue = rawCues.optJSONObject(index) ?: continue
                val fromMs = readSubtitleTimeMs(rawCue.opt("from")) ?: continue
                val toMs = readSubtitleTimeMs(rawCue.opt("to")) ?: continue
                val content = limitSubtitleText(
                    rawCue.optString("content").trim(),
                    MAX_SUBTITLE_CUE_CODE_POINTS,
                )
                if (toMs <= fromMs || content.isBlank()) {
                    continue
                }
                cues.add(
                    mapOf(
                        "fromMs" to fromMs,
                        "toMs" to toMs,
                        "content" to content,
                    ),
                )
            }
        }
        return if (cues.isEmpty()) {
            subtitleCueResult(
                status = SUBTITLE_STATUS_NONE,
                message = "此字幕轨道没有可显示内容。",
            )
        } else {
            subtitleCueResult(status = SUBTITLE_STATUS_AVAILABLE, cues = cues)
        }
    }

    /** 使用固定的播放器元数据地址请求当前分P字幕信息，不允许调用方提供任意主机。 */
    private fun requestSubtitleMetadataJson(bvid: String, cid: Long): String {
        val endpoint = Uri.Builder()
            .scheme("https")
            .authority(PLAYBACK_API_HOST)
            .appendPath("x")
            .appendPath("player")
            .appendPath("v2")
            .appendQueryParameter("bvid", bvid)
            .appendQueryParameter("cid", cid.toString())
            .build()
        return requestLimitedSubtitleJson(
            endpoint = endpoint.toString(),
            referer = buildVideoPageUrl(bvid).orEmpty(),
            maximumBytes = MAX_SUBTITLE_METADATA_BYTES,
            includeSessionCookie = true,
        )
    }

    /** 请求已通过固定 CDN 主机校验的临时字幕 JSON，临时地址不会离开原生层。 */
    private fun requestSubtitleDocumentJson(subtitleUrl: String, bvid: String): String {
        return requestLimitedSubtitleJson(
            endpoint = subtitleUrl,
            referer = buildVideoPageUrl(bvid).orEmpty(),
            maximumBytes = MAX_SUBTITLE_DOCUMENT_BYTES,
            includeSessionCookie = false,
        )
    }

    /**
     * 以固定请求头读取小于上限的 JSON 响应，并仅在原生内存中短暂使用 WebView 会话。
     *
     * 该函数不记录请求头、Cookie、地址参数或响应正文，防止临时授权资料进入日志。
     */
    private fun requestLimitedSubtitleJson(
        endpoint: String,
        referer: String,
        maximumBytes: Int,
        includeSessionCookie: Boolean,
    ): String {
        val connection = URL(endpoint).openConnection() as? HttpsURLConnection
            ?: throw SubtitleOperationException("subtitle_invalid_url", "字幕地址无效。")
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = NETWORK_TIMEOUT_MS
            connection.readTimeout = NETWORK_TIMEOUT_MS
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Referer", referer)
            connection.setRequestProperty("User-Agent", DESKTOP_USER_AGENT)
            if (includeSessionCookie) {
                readBilibiliCookieHeader().takeIf { cookie -> cookie.isNotBlank() }?.let { cookie ->
                    connection.setRequestProperty("Cookie", cookie)
                }
            }
            val statusCode = connection.responseCode
            if (statusCode !in 200..299) {
                throw SubtitleOperationException(
                    "subtitle_network",
                    "字幕服务暂时不可用（HTTP $statusCode）。",
                )
            }
            val responseBody = connection.inputStream.use { stream ->
                readLimitedUtf8Text(stream.readBytesWithLimit(maximumBytes))
            }
            if (responseBody.isBlank()) {
                throw SubtitleOperationException("subtitle_invalid_data", "字幕数据为空。")
            }
            return responseBody
        } finally {
            connection.disconnect()
        }
    }

    /** 将字节流复制到受限缓冲区；超过上限时立刻停止，避免异常字幕包耗尽内存。 */
    private fun java.io.InputStream.readBytesWithLimit(maximumBytes: Int): ByteArray {
        val buffer = ByteArray(SUBTITLE_RESPONSE_BUFFER_BYTES)
        val output = ByteArrayOutputStream()
        while (true) {
            val read = read(buffer)
            if (read < 0) {
                break
            }
            if (output.size() + read > maximumBytes) {
                throw SubtitleOperationException(
                    "subtitle_too_large",
                    "字幕内容过大，暂时无法读取。",
                )
            }
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }

    /** 将受限响应字节按 UTF-8 转成 JSON 文本；替换字符会在后续 JSON 解析中安全失败。 */
    private fun readLimitedUtf8Text(bytes: ByteArray): String {
        return String(bytes, Charsets.UTF_8)
    }

    /** 解析字幕 JSON，解析失败时只给出通用提示，不暴露服务端原文。 */
    private fun parseSubtitleJson(responseText: String): JSONObject {
        return try {
            JSONObject(responseText)
        } catch (_: Exception) {
            throw SubtitleOperationException("subtitle_invalid_data", "字幕数据格式不正确。")
        }
    }

    /** 从轨道字典取稳定 ID，兼容字符串和数值字段但拒绝空值与过长编号。 */
    private fun readSubtitleTrackId(track: JSONObject): String? {
        val rawId = track.optString("id_str").trim().ifBlank {
            track.opt("id")?.toString()?.trim().orEmpty()
        }
        return rawId.takeIf { id ->
            id.length <= MAX_SUBTITLE_TRACK_ID_LENGTH && SUBTITLE_TRACK_ID_PATTERN.matches(id)
        }
    }

    /** 只接受协议相对或 HTTPS 的官方字幕 CDN 地址，避免服务端异常数据触发任意网络访问。 */
    private fun normalizeSafeSubtitleUrl(rawUrl: String): String? {
        val normalized = when {
            rawUrl.startsWith("//") -> "https:$rawUrl"
            rawUrl.startsWith("https://", ignoreCase = true) -> rawUrl
            else -> return null
        }
        val uri = runCatching { Uri.parse(normalized) }.getOrNull() ?: return null
        val host = uri.host?.lowercase(Locale.ROOT) ?: return null
        if (!uri.scheme.equals("https", ignoreCase = true) || host != SUBTITLE_CDN_HOST) {
            return null
        }
        return uri.toString()
    }

    /** 将接口中的秒级时间安全转换为毫秒，异常、负数和超长时长都会被拒绝。 */
    private fun readSubtitleTimeMs(rawValue: Any?): Long? {
        val seconds = when (rawValue) {
            is Number -> rawValue.toDouble()
            is String -> rawValue.toDoubleOrNull()
            else -> null
        } ?: return null
        if (!seconds.isFinite() || seconds < 0.0 || seconds > MAX_SUBTITLE_DURATION_SECONDS) {
            return null
        }
        return (seconds * 1000.0).toLong()
    }

    /** 按 Unicode 码点裁剪字幕文字，避免截断 emoji 并限制页面渲染压力。 */
    private fun limitSubtitleText(value: String, maximumCodePoints: Int): String {
        if (value.isBlank() || maximumCodePoints <= 0) {
            return ""
        }
        val codePointCount = value.codePointCount(0, value.length)
        if (codePointCount <= maximumCodePoints) {
            return value
        }
        return value.substring(0, value.offsetByCodePoints(0, maximumCodePoints))
    }

    /** 构造不包含临时地址的字幕轨道响应，供 Flutter 菜单显示可用、锁定或空状态。 */
    private fun subtitleTrackResult(
        status: String,
        message: String = "",
        tracks: List<SubtitleTrackOption> = emptyList(),
    ): Map<String, Any> {
        return mapOf(
            "status" to status,
            "message" to message,
            "tracks" to tracks.map { track ->
                mapOf(
                    "id" to track.id,
                    "language" to track.language,
                    "label" to track.label,
                    "isLocked" to track.isLocked,
                )
            },
        )
    }

    /** 构造不包含服务端地址和会话资料的字幕条目响应。 */
    private fun subtitleCueResult(
        status: String,
        message: String = "",
        cues: List<Map<String, Any>> = emptyList(),
    ): Map<String, Any> {
        return mapOf(
            "status" to status,
            "message" to message,
            "cues" to cues,
        )
    }

    /** 将字幕请求异常转换成稳定错误码和中文说明，避免 Throwable 原文泄露网络资料。 */
    private fun reportSubtitleOperationFailure(result: MethodChannel.Result, error: Throwable) {
        if (error is SubtitleOperationException) {
            result.error(error.errorCode, error.message, null)
        } else {
            result.error("subtitle_unavailable", "字幕暂时无法读取，请稍后重试。", null)
        }
    }

    /**
     * 在受限后台队列读取一个六分钟弹幕段，避免高频预取影响播放数据请求。
     *
     * 请求只使用 BV、CID 和段号；用户会话仅在原生请求头中短暂使用，不会经过方法通道。
     */
    private fun requestDanmakuSegment(
        bvid: String,
        cid: Long,
        segmentIndex: Int,
        result: MethodChannel.Result,
    ) {
        runCatching {
            overlayDataRequestExecutor.execute {
                val segmentResult = runCatching {
                    loadDanmakuSegment(bvid, cid, segmentIndex)
                }
                mainHandler.post {
                    segmentResult.onSuccess(result::success).onFailure { error ->
                        reportDanmakuOperationFailure(result, error)
                    }
                }
            }
        }.onFailure {
            result.error("danmaku_unavailable", "弹幕暂时无法读取，请稍后重试。", null)
        }
    }

    /** 读取固定 B 站分段接口的 Protobuf 数据，并转换成 Flutter 只需的四项展示字段。 */
    private fun loadDanmakuSegment(
        bvid: String,
        cid: Long,
        segmentIndex: Int,
    ): Map<String, Any> {
        val entries = parseDanmakuSegment(
            requestDanmakuSegmentBytes(bvid, cid, segmentIndex),
        )
        return if (entries.isEmpty()) {
            danmakuSegmentResult(
                status = DANMAKU_STATUS_NONE,
                segmentIndex = segmentIndex,
                message = "当前六分钟片段没有可显示弹幕。",
            )
        } else {
            danmakuSegmentResult(
                status = DANMAKU_STATUS_AVAILABLE,
                segmentIndex = segmentIndex,
                entries = entries,
            )
        }
    }

    /**
     * 请求固定的网页分段弹幕地址，不接受任意主机、路径或请求参数。
     *
     * 该接口返回 Protobuf；Cookie 仅留在本次 HTTPS 请求头，不会保存或回传给 Dart。
     */
    private fun requestDanmakuSegmentBytes(
        bvid: String,
        cid: Long,
        segmentIndex: Int,
    ): ByteArray {
        val endpoint = Uri.Builder()
            .scheme("https")
            .authority(PLAYBACK_API_HOST)
            .appendPath("x")
            .appendPath("v2")
            .appendPath("dm")
            .appendPath("web")
            .appendPath("seg.so")
            .appendQueryParameter("type", "1")
            .appendQueryParameter("oid", cid.toString())
            .appendQueryParameter("segment_index", segmentIndex.toString())
            .build()
        val connection = URL(endpoint.toString()).openConnection() as? HttpsURLConnection
            ?: throw DanmakuOperationException("danmaku_invalid_url", "弹幕地址无效。")
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = NETWORK_TIMEOUT_MS
            connection.readTimeout = NETWORK_TIMEOUT_MS
            connection.setRequestProperty("Accept", "application/octet-stream")
            connection.setRequestProperty("Accept-Encoding", "identity")
            connection.setRequestProperty("Referer", buildVideoPageUrl(bvid).orEmpty())
            connection.setRequestProperty("User-Agent", DESKTOP_USER_AGENT)
            readBilibiliCookieHeader().takeIf { cookie -> cookie.isNotBlank() }?.let { cookie ->
                connection.setRequestProperty("Cookie", cookie)
            }
            val statusCode = connection.responseCode
            if (statusCode !in 200..299) {
                throw DanmakuOperationException(
                    "danmaku_network",
                    "弹幕服务暂时不可用（HTTP $statusCode）。",
                )
            }
            return connection.inputStream.use(::readDanmakuBytesWithLimit)
        } finally {
            connection.disconnect()
        }
    }

    /** 将弹幕响应复制到受限缓冲区；超过上限时停止读取，避免单段异常数据耗尽内存。 */
    private fun readDanmakuBytesWithLimit(stream: java.io.InputStream): ByteArray {
        val buffer = ByteArray(DANMAKU_RESPONSE_BUFFER_BYTES)
        val output = ByteArrayOutputStream()
        while (true) {
            val read = stream.read(buffer)
            if (read < 0) {
                break
            }
            if (output.size() + read > MAX_DANMAKU_SEGMENT_BYTES) {
                throw DanmakuOperationException(
                    "danmaku_too_large",
                    "弹幕数据过大，暂时无法读取。",
                )
            }
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }

    /**
     * 解析 `DmSegMobileReply` 的 repeated `elems` 字段，并容错跳过单条损坏弹幕。
     *
     * 不支持的顶层字段会按 Protobuf 线格式跳过；整个包结构损坏时才返回明确错误。
     */
    private fun parseDanmakuSegment(responseBytes: ByteArray): List<DanmakuElement> {
        if (responseBytes.isEmpty()) {
            return emptyList()
        }
        val cursor = ProtobufCursor(responseBytes)
        val entries = mutableListOf<DanmakuElement>()
        while (cursor.hasRemaining()) {
            val tag = cursor.readVarint()
            val fieldNumber = tag ushr 3
            val wireType = (tag and PROTOBUF_WIRE_TYPE_MASK).toInt()
            if (fieldNumber <= 0L) {
                throw DanmakuOperationException("danmaku_invalid_data", "弹幕数据格式不正确。")
            }
            if (fieldNumber == DMSegMobileReply_ELEMS_FIELD_NUMBER.toLong() &&
                wireType == PROTOBUF_LENGTH_DELIMITED_WIRE_TYPE
            ) {
                val elementBytes = cursor.readLengthDelimited()
                val element = runCatching { parseDanmakuElement(elementBytes) }.getOrNull()
                if (element != null && entries.size < MAX_DANMAKU_ENTRIES) {
                    entries.add(element)
                }
            } else {
                cursor.skipField(wireType)
            }
        }
        return entries
    }

    /** 解析一条 `DanmakuElem`，只保留进度、内容、颜色和模式，其他字段全部跳过。 */
    private fun parseDanmakuElement(elementBytes: ByteArray): DanmakuElement? {
        val cursor = ProtobufCursor(elementBytes)
        var progressMs: Long? = null
        var content: String? = null
        var color = DEFAULT_DANMAKU_COLOR
        var mode = DEFAULT_DANMAKU_MODE
        while (cursor.hasRemaining()) {
            val tag = cursor.readVarint()
            val fieldNumber = tag ushr 3
            val wireType = (tag and PROTOBUF_WIRE_TYPE_MASK).toInt()
            if (fieldNumber <= 0L) {
                return null
            }
            when {
                fieldNumber == DANMAKU_PROGRESS_FIELD_NUMBER.toLong() &&
                    wireType == PROTOBUF_VARINT_WIRE_TYPE -> {
                    progressMs = cursor.readVarint()
                }
                fieldNumber == DANMAKU_MODE_FIELD_NUMBER.toLong() &&
                    wireType == PROTOBUF_VARINT_WIRE_TYPE -> {
                    val rawMode = cursor.readVarint()
                    if (rawMode in MIN_DANMAKU_MODE.toLong()..MAX_DANMAKU_MODE.toLong()) {
                        mode = rawMode.toInt()
                    }
                }
                fieldNumber == DANMAKU_COLOR_FIELD_NUMBER.toLong() &&
                    wireType == PROTOBUF_VARINT_WIRE_TYPE -> {
                    color = (cursor.readVarint() and DANMAKU_RGB_MASK).toInt()
                }
                fieldNumber == DANMAKU_CONTENT_FIELD_NUMBER.toLong() &&
                    wireType == PROTOBUF_LENGTH_DELIMITED_WIRE_TYPE -> {
                    content = limitDanmakuText(
                        String(cursor.readLengthDelimited(), Charsets.UTF_8).trim(),
                    )
                }
                else -> cursor.skipField(wireType)
            }
        }
        val safeProgressMs = progressMs?.takeIf { progress ->
            progress in 0L..MAX_DANMAKU_PROGRESS_MS
        } ?: return null
        val safeContent = content?.takeIf { value -> value.isNotBlank() } ?: return null
        return DanmakuElement(
            progressMs = safeProgressMs,
            content = safeContent,
            color = color,
            mode = mode,
        )
    }

    /** 按 Unicode 码点裁剪弹幕文本，避免单条异常长内容拖慢后续 Flutter 渲染。 */
    private fun limitDanmakuText(value: String): String {
        return limitSubtitleText(value, MAX_DANMAKU_CONTENT_CODE_POINTS)
    }

    /** 构造不包含原始 Protobuf、Cookie 或网络地址的单段弹幕响应。 */
    private fun danmakuSegmentResult(
        status: String,
        segmentIndex: Int,
        message: String = "",
        entries: List<DanmakuElement> = emptyList(),
    ): Map<String, Any> {
        return mapOf(
            "status" to status,
            "message" to message,
            "segmentIndex" to segmentIndex,
            "entries" to entries.map { entry ->
                mapOf(
                    "progressMs" to entry.progressMs,
                    "content" to entry.content,
                    "color" to entry.color,
                    "mode" to entry.mode,
                )
            },
        )
    }

    /** 将弹幕请求异常转换成稳定错误码和中文说明，避免 Throwable 原文泄露网络资料。 */
    private fun reportDanmakuOperationFailure(result: MethodChannel.Result, error: Throwable) {
        if (error is DanmakuOperationException) {
            result.error(error.errorCode, error.message, null)
        } else {
            result.error("danmaku_unavailable", "弹幕暂时无法读取，请稍后重试。", null)
        }
    }

    /**
     * 提供最小 Protobuf 游标，只解析弹幕所需的 varint 与长度字段并安全跳过未知字段。
     *
     * 该解析器不依赖额外第三方库，所有越界、长度溢出和非法 wire type 都会抛出可控异常。
     */
    private class ProtobufCursor(private val payload: ByteArray) {
        private var position = 0

        /** 返回当前缓冲区是否还有未读取字节。 */
        fun hasRemaining(): Boolean = position < payload.size

        /** 读取一个最多十字节的无符号 varint，截断或超长编码会被拒绝。 */
        fun readVarint(): Long {
            var value = 0L
            var shift = 0
            repeat(MAX_PROTOBUF_VARINT_BYTES) {
                if (!hasRemaining()) {
                    throw DanmakuOperationException("danmaku_invalid_data", "弹幕数据格式不正确。")
                }
                val currentByte = payload[position++].toInt() and 0xff
                value = value or ((currentByte and PROTOBUF_VARINT_VALUE_MASK).toLong() shl shift)
                if ((currentByte and PROTOBUF_VARINT_CONTINUATION_MASK) == 0) {
                    return value
                }
                shift += PROTOBUF_VARINT_SHIFT_BITS
            }
            throw DanmakuOperationException("danmaku_invalid_data", "弹幕数据格式不正确。")
        }

        /** 读取一个长度分隔字段，并验证声明长度没有越过当前 Protobuf 包边界。 */
        fun readLengthDelimited(): ByteArray {
            val length = readVarint()
            skipBytes(length)
            val end = position
            val start = end - length.toInt()
            return payload.copyOfRange(start, end)
        }

        /** 根据 wire type 安全跳过一个未知字段，保证协议新增字段不会破坏当前解析。 */
        fun skipField(wireType: Int) {
            when (wireType) {
                PROTOBUF_VARINT_WIRE_TYPE -> readVarint()
                PROTOBUF_FIXED_64_WIRE_TYPE -> skipBytes(PROTOBUF_FIXED_64_BYTE_COUNT.toLong())
                PROTOBUF_LENGTH_DELIMITED_WIRE_TYPE -> skipBytes(readVarint())
                PROTOBUF_FIXED_32_WIRE_TYPE -> skipBytes(PROTOBUF_FIXED_32_BYTE_COUNT.toLong())
                else -> throw DanmakuOperationException(
                    "danmaku_invalid_data",
                    "弹幕数据格式不正确。",
                )
            }
        }

        /** 向前移动指定字节数并验证长度、剩余空间和 Int 转换均安全。 */
        private fun skipBytes(length: Long) {
            val remaining = payload.size - position
            if (length < 0L || length > remaining.toLong()) {
                throw DanmakuOperationException("danmaku_invalid_data", "弹幕数据格式不正确。")
            }
            position += length.toInt()
        }
    }

    /** 把接口返回的清晰度编号与描述组合成稳定且去重的菜单列表。 */
    private fun parseQualityOptions(
        data: JSONObject,
        dash: JSONObject,
    ): List<PlaybackQualityOption> {
        val qualities = mutableListOf<PlaybackQualityOption>()
        val ids = data.optJSONArray("accept_quality")
        val descriptions = data.optJSONArray("accept_description")
        if (ids != null) {
            for (index in 0 until ids.length()) {
                val id = ids.optInt(index)
                if (id <= 0 || qualities.any { option -> option.id == id }) {
                    continue
                }
                val description = descriptions?.optString(index).orEmpty()
                qualities.add(
                    PlaybackQualityOption(
                        id = id,
                        label = description.ifBlank { qualityFallbackLabel(id) },
                    ),
                )
            }
        }
        if (qualities.isEmpty()) {
            val videoTracks = dash.optJSONArray("video")
            if (videoTracks != null) {
                for (index in 0 until videoTracks.length()) {
                    val id = videoTracks.optJSONObject(index)?.optInt("id") ?: 0
                    if (id > 0 && qualities.none { option -> option.id == id }) {
                        qualities.add(PlaybackQualityOption(id, qualityFallbackLabel(id)))
                    }
                }
            }
        }
        if (qualities.none { option -> option.id == currentQuality }) {
            qualities.add(
                PlaybackQualityOption(currentQuality, qualityFallbackLabel(currentQuality)),
            )
        }
        return qualities.sortedByDescending { option -> option.id }
    }

    /** 为缺少接口描述的常见质量编号生成简短中文名称。 */
    private fun qualityFallbackLabel(quality: Int): String {
        return when (quality) {
            127 -> "超高清 8K"
            120 -> "超清 4K"
            116 -> "高清 1080P60"
            112 -> "高清 1080P+"
            80 -> "高清 1080P"
            64 -> "高清 720P"
            32 -> "清晰 480P"
            16 -> "流畅 360P"
            else -> "清晰度 $quality"
        }
    }

    /** 从 DASH 轨道选择目标质量并优先 AVC/H.264，避开部分 HEVC 初始化数据解析崩溃。 */
    private fun selectMediaTrack(
        mediaItems: JSONArray?,
        preferredId: Int? = null,
    ): SelectedMediaTrack {
        if (mediaItems == null) {
            return SelectedMediaTrack(emptyList(), "")
        }
        var selectedMedia: JSONObject? = null
        var bestScore = Long.MIN_VALUE
        for (index in 0 until mediaItems.length()) {
            val media = mediaItems.optJSONObject(index) ?: continue
            val candidateUrls = readMediaUrls(media)
            if (candidateUrls.isEmpty()) {
                continue
            }
            val qualityBonus = if (preferredId != null && media.optInt("id") == preferredId) {
                PREFERRED_TRACK_SCORE
            } else {
                0L
            }
            val compatibilityBonus = if (preferredId != null) {
                PlaybackTrackPolicy.compatibilityScore(media.optString("codecs"))
            } else {
                0L
            }
            val heightScore = media.optInt("height").coerceAtLeast(0).toLong() * HEIGHT_SCORE_UNIT
            val bandwidthScore = media.optLong("bandwidth").coerceAtLeast(0L)
            val score = qualityBonus + compatibilityBonus + heightScore + bandwidthScore
            if (score > bestScore) {
                selectedMedia = media
                bestScore = score
            }
        }
        return selectedMedia?.let { media ->
            SelectedMediaTrack(
                urls = readMediaUrls(media),
                codec = media.optString("codecs").trim(),
            )
        } ?: SelectedMediaTrack(emptyList(), "")
    }

    /** 从一条 DASH 轨道读取并去重主备地址，只保留 B 站 HTTPS 媒体域名。 */
    private fun readMediaUrls(media: JSONObject): List<String> {
        val urls = linkedSetOf<String>()
        val primaryUrl = media.optString("base_url").ifBlank {
            media.optString("baseUrl")
        }
        if (isSafeMediaUrl(primaryUrl)) {
            urls.add(primaryUrl)
        }
        val backupUrls = media.optJSONArray("backup_url") ?: media.optJSONArray("backupUrl")
        if (backupUrls != null) {
            for (index in 0 until backupUrls.length()) {
                val backupUrl = backupUrls.optString(index)
                if (isSafeMediaUrl(backupUrl)) {
                    urls.add(backupUrl)
                }
            }
        }
        return urls.toList()
    }

    /** 使用桌面 UA、视频页 Referer 和受容量限制的本地缓存创建 Media3 数据源。 */
    private fun createMediaDataSourceFactory(referer: String): DataSource.Factory {
        val requestProperties = mutableMapOf(
            "Accept" to "*/*",
            "Accept-Encoding" to "identity",
            "Origin" to "https://www.bilibili.com",
            "Referer" to referer,
            "User-Agent" to DESKTOP_USER_AGENT,
        )
        readBilibiliCookieHeader().takeIf { cookie -> cookie.isNotBlank() }?.let { cookie ->
            requestProperties["Cookie"] = cookie
        }
        val networkFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(MEDIA_CONNECT_TIMEOUT_MS)
            .setReadTimeoutMs(MEDIA_READ_TIMEOUT_MS)
            .setDefaultRequestProperties(requestProperties)
        return CacheDataSource.Factory()
            .setCache(ensureMediaCache())
            .setUpstreamDataSourceFactory(networkFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }

    /**
     * 延迟创建当前设置容量的 LRU 边播边缓存，容量满后自动删除最久未使用的数据。
     *
     * 该缓存只减少短期重复请求，不保存完整视频，也不构成离线下载。
     */
    private fun ensureMediaCache(): SimpleCache {
        mediaCache?.let { cache -> return cache }
        val cacheDirectory = File(activity.cacheDir, MEDIA_CACHE_DIRECTORY_NAME)
        val cache = SimpleCache(
            cacheDirectory,
            LeastRecentlyUsedCacheEvictor(readConfiguredMediaCacheCapacity()),
            cacheDatabaseProvider,
        )
        mediaCache = cache
        return cache
    }

    /** 将缓存操作统一转换为 MethodChannel 的成功结果或可识别错误码。 */
    private fun handleMediaCacheOperation(
        result: MethodChannel.Result,
        operation: () -> Map<String, Any>,
    ) {
        try {
            result.success(operation())
        } catch (exception: CacheOperationException) {
            result.error(exception.errorCode, exception.message, null)
        } catch (_: Exception) {
            result.error("cache_error", "视频缓存暂时无法操作，请稍后重试。", null)
        }
    }

    /** 返回缓存占用、已配置上限和播放器是否仍占用缓存的当前快照。 */
    private fun readMediaCacheStatus(): Map<String, Any> {
        val cache = ensureMediaCache()
        return mapOf(
            "usedBytes" to cache.cacheSpace,
            "capacityBytes" to readConfiguredMediaCacheCapacity(),
            "isPlaybackActive" to isMediaPlaybackActive(),
        )
    }

    /**
     * 在没有活跃播放器时保存新的上限，并重新打开缓存以让新的 LRU 淘汰策略生效。
     *
     * 使用同步 `commit`，只有持久化成功后才向 Flutter 报告成功，避免 App 被杀死时设置丢失。
     */
    private fun setMediaCacheCapacity(capacityBytes: Long): Map<String, Any> {
        requireMediaCacheIdle()
        if (readConfiguredMediaCacheCapacity() == capacityBytes) {
            return readMediaCacheStatus()
        }
        releaseMediaCache()
        val saved = cachePreferences.edit()
            .putLong(CACHE_CAPACITY_PREFERENCE_KEY, capacityBytes)
            .commit()
        if (!saved) {
            throw CacheOperationException("cache_error", "无法保存视频缓存上限，请稍后重试。")
        }
        return readMediaCacheStatus()
    }

    /** 在没有活跃播放器时删除所有缓存资源，并返回清理后的缓存快照。 */
    private fun clearMediaCache(): Map<String, Any> {
        requireMediaCacheIdle()
        val cache = ensureMediaCache()
        cache.keys.toList().forEach { cacheKey ->
            cache.removeResource(cacheKey)
        }
        return readMediaCacheStatus()
    }

    /** 确认播放器尚未创建；暂停但仍在播放页的播放器同样视为占用缓存。 */
    private fun requireMediaCacheIdle() {
        if (isMediaPlaybackActive()) {
            throw CacheOperationException(
                "cache_busy",
                "视频播放中，停止播放并退出播放页后才能管理缓存。",
            )
        }
    }

    /** 返回是否存在仍可能读取缓存的 Media3 播放器实例。 */
    private fun isMediaPlaybackActive(): Boolean = player != null

    /** 读取已持久化的上限，遇到旧版本或异常值时安全回退为默认 512MB。 */
    private fun readConfiguredMediaCacheCapacity(): Long {
        val savedCapacity = cachePreferences.getLong(
            CACHE_CAPACITY_PREFERENCE_KEY,
            MEDIA_CACHE_DEFAULT_MAX_BYTES,
        )
        return savedCapacity.takeIf(::isSupportedMediaCacheCapacity)
            ?: MEDIA_CACHE_DEFAULT_MAX_BYTES
    }

    /** 只接受界面明确提供的五档容量，避免任意数值造成不可预测的磁盘占用。 */
    private fun isSupportedMediaCacheCapacity(capacityBytes: Long): Boolean {
        return SUPPORTED_MEDIA_CACHE_CAPACITIES.contains(capacityBytes)
    }

    /** 选择当前主备线路地址，越界时回退到该轨道的第一条安全地址。 */
    private fun mediaUrlAt(urls: List<String>, index: Int): String {
        if (urls.isEmpty()) {
            return ""
        }
        return urls.getOrElse(index) { urls.first() }
    }

    /** 合并当前候选线路的 DASH 音视频，并按历史位置、倍速和播放状态启动唯一播放器。 */
    private fun prepareMediaSources(sources: PlaybackSources) {
        val nativePlayer = player ?: return
        if (latestPlaybackSources !== sources) {
            latestPlaybackSources = sources
            playbackSourceAttemptIndex = 0
        }
        currentQuality = sources.actualQuality
        availableQualities = sources.qualities
        val videoUrl = mediaUrlAt(sources.videoUrls, playbackSourceAttemptIndex)
        val audioUrl = mediaUrlAt(sources.audioUrls, playbackSourceAttemptIndex)
        val displayTitle = buildMediaDisplayTitle()
        val mediaMetadata = MediaMetadata.Builder()
            .setTitle(displayTitle)
            .setArtist(currentOwnerName.ifBlank { "未知 UP 主" })
            .build()
        val sourceFactory = ProgressiveMediaSource.Factory(
            createMediaDataSourceFactory(sources.referer),
        ).setLoadErrorHandlingPolicy(
            DefaultLoadErrorHandlingPolicy(MEDIA_MINIMUM_RETRY_COUNT),
        )
        val videoItem = MediaItem.Builder()
            .setMediaId("$currentBvid:$currentCid:$currentQuality")
            .setUri(videoUrl)
            .setCustomCacheKey(
                "$currentBvid:$currentCid:$currentQuality:" +
                    "${PlaybackTrackPolicy.cacheKey(sources.videoCodec)}:video",
            )
            .setMediaMetadata(mediaMetadata)
            .build()
        val videoSource = sourceFactory.createMediaSource(videoItem)
        val finalSource: MediaSource = if (isSafeMediaUrl(audioUrl)) {
            val audioSource = sourceFactory.createMediaSource(
                MediaItem.Builder()
                    .setUri(audioUrl)
                    .setCustomCacheKey(
                        "$currentBvid:$currentCid:$currentQuality:" +
                            "${PlaybackTrackPolicy.cacheKey(sources.audioCodec)}:audio",
                    )
                    .build(),
            )
            MergingMediaSource(videoSource, audioSource)
        } else {
            videoSource
        }
        playbackPhase = PHASE_LOADING
        playbackMessage = "正在准备原生播放器…"
        nativePlayer.setMediaSource(finalSource)
        if (pendingStartPositionMs > 0L) {
            nativePlayer.seekTo(pendingStartPositionMs)
        }
        pendingStartPositionMs = 0L
        nativePlayer.playbackParameters = PlaybackParameters(playbackSpeed)
        nativePlayer.prepare()
        if (resumeAfterPrepare) {
            nativePlayer.play()
        } else {
            nativePlayer.pause()
        }
        emitPlaybackState()
    }

    /** 组合视频标题和分P标题，作为系统控制中心显示的媒体标题。 */
    private fun buildMediaDisplayTitle(): String {
        val title = currentTitle.ifBlank { "焦点哔哩视频" }
        val partTitle = currentPartTitle.trim()
        return if (partTitle.isEmpty() || partTitle == title) {
            title
        } else {
            "$title · $partTitle"
        }
    }

    /** 将网络或解析异常转换为用户能理解的播放失败提示。 */
    private fun describePlaybackFetchFailure(error: Throwable): String {
        if (error is PlaybackSourceException) {
            return error.message ?: "无法取得播放数据。"
        }
        return "无法请求播放数据，请检查网络后重试。"
    }

    /** 为新的异步请求生成编号，使旧视频迟到的网络结果自动失效。 */
    private fun createPlaybackRequestToken(): Long {
        playbackRequestToken += 1L
        return playbackRequestToken
    }

    /** 使正在执行的播放数据请求失效，防止释放或切换后继续改动播放器。 */
    private fun invalidatePlaybackRequests() {
        playbackRequestToken += 1L
    }

    /** 判断后台数据是否仍属于当前视频、分P和最新清晰度请求。 */
    private fun isCurrentPlaybackRequest(
        requestToken: Long,
        bvid: String,
        cid: Long,
        quality: Int,
    ): Boolean {
        return requestToken == playbackRequestToken &&
            bvid == currentBvid &&
            cid == currentCid &&
            quality == requestedQuality
    }

    /** 按给定毫秒数前进或后退，并把位置限制在视频有效范围内。 */
    private fun seekBy(offsetMs: Long) {
        val nativePlayer = player ?: return
        val duration = nativePlayer.duration.takeIf { it > 0 } ?: Long.MAX_VALUE
        val target = (nativePlayer.currentPosition + offsetMs).coerceIn(0L, duration)
        nativePlayer.seekTo(target)
        saveCurrentPlaybackProgress(force = true, positionOverrideMs = target)
        emitPlaybackState()
    }

    /** 跳转到指定绝对位置，并立即保存拖动进度条得到的新位置。 */
    private fun seekToPosition(positionMs: Long) {
        val nativePlayer = player ?: return
        val duration = nativePlayer.duration.takeIf { it > 0 } ?: Long.MAX_VALUE
        val target = positionMs.coerceIn(0L, duration)
        nativePlayer.seekTo(target)
        saveCurrentPlaybackProgress(force = true, positionOverrideMs = target)
        emitPlaybackState()
    }

    /** 将播放器状态、倍速和清晰度列表发送给 Flutter。 */
    private fun emitPlaybackState() {
        val nativePlayer = player
        val duration = nativePlayer?.duration?.takeIf { it > 0 } ?: 0L
        val position = nativePlayer?.currentPosition?.coerceAtLeast(0L) ?: 0L
        channel.invokeMethod(
            "playbackEvent",
            mapOf(
                "phase" to playbackPhase,
                "isPlaying" to (nativePlayer?.isPlaying == true),
                "positionMs" to position,
                "durationMs" to duration,
                "speed" to playbackSpeed.toDouble(),
                "quality" to currentQuality,
                "qualities" to availableQualities.map { quality ->
                    mapOf("id" to quality.id, "label" to quality.label)
                },
                "aspectRatio" to videoAspectRatio.toDouble(),
                "restoredPositionMs" to restoredPositionMs,
                "isInPictureInPicture" to isInPictureInPicture,
                "message" to playbackMessage,
            ),
        )
    }

    /** 将错误状态连同用户能理解的说明发送到 Flutter 播放页面。 */
    private fun reportError(message: String) {
        playbackPrepared = false
        playbackPhase = PHASE_ERROR
        playbackMessage = message
        resumeAfterPrepare = false
        player?.pause()
        updateKeepScreenOn(false)
        emitPlaybackState()
    }

    /** 按固定间隔或强制时机保存当前分P进度，接近结尾时清除记录。 */
    private fun saveCurrentPlaybackProgress(
        force: Boolean,
        positionOverrideMs: Long? = null,
    ) {
        val nativePlayer = player ?: return
        if (currentBvid.isEmpty() || currentCid <= 0L) {
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (!force && now - lastProgressSaveElapsedMs < PROGRESS_SAVE_INTERVAL_MS) {
            return
        }
        val duration = nativePlayer.duration
        val position = (positionOverrideMs ?: nativePlayer.currentPosition).coerceAtLeast(0L)
        if (duration <= 0L) {
            return
        }
        lastProgressSaveElapsedMs = now
        if (duration - position <= COMPLETED_REMAINING_MS) {
            clearSavedPlaybackProgress(currentBvid, currentCid)
            return
        }
        progressPreferences.edit()
            .putLong(progressPositionKey(currentBvid, currentCid), position)
            .putLong(progressDurationKey(currentBvid, currentCid), duration)
            .apply()
    }

    /** 读取可继续观看的历史位置；太靠前或接近结尾的记录视为无效。 */
    private fun loadSavedPlaybackPosition(bvid: String, cid: Long): Long {
        val position = progressPreferences.getLong(progressPositionKey(bvid, cid), 0L)
        val duration = progressPreferences.getLong(progressDurationKey(bvid, cid), 0L)
        if (position < MIN_RESUME_POSITION_MS ||
            duration <= 0L ||
            duration - position <= COMPLETED_REMAINING_MS
        ) {
            clearSavedPlaybackProgress(bvid, cid)
            return 0L
        }
        return position.coerceAtMost(duration)
    }

    /** 保存整支视频最后观看的分P，使下次进入时先打开同一分P。 */
    private fun saveCurrentPartSelection() {
        if (currentBvid.isEmpty() || currentCid <= 0L || currentPageNumber <= 0) {
            return
        }
        progressPreferences.edit()
            .putLong(lastPartCidKey(currentBvid), currentCid)
            .putInt(lastPartPageKey(currentBvid), currentPageNumber)
            .apply()
    }

    /** 读取整支视频最后观看的分P及其可恢复位置，供 Flutter 进入页面前定位。 */
    private fun loadSavedVideoState(bvid: String): Map<String, Any>? {
        if (buildVideoPageUrl(bvid) == null) {
            return null
        }
        val cid = progressPreferences.getLong(lastPartCidKey(bvid), 0L)
        val pageNumber = progressPreferences.getInt(lastPartPageKey(bvid), 0)
        if (cid <= 0L || pageNumber <= 0) {
            return null
        }
        return mapOf(
            "cid" to cid,
            "pageNumber" to pageNumber,
            "positionMs" to loadSavedPlaybackPosition(bvid, cid),
        )
    }

    /** 删除一条已看完或无效的分P播放记忆。 */
    private fun clearSavedPlaybackProgress(bvid: String, cid: Long) {
        if (bvid.isEmpty() || cid <= 0L) {
            return
        }
        progressPreferences.edit()
            .remove(progressPositionKey(bvid, cid))
            .remove(progressDurationKey(bvid, cid))
            .apply()
    }

    /** 生成某个分P的进度位置存储键。 */
    private fun progressPositionKey(bvid: String, cid: Long): String {
        return "progress:$bvid:$cid:position"
    }

    /** 生成某个分P的总时长存储键。 */
    private fun progressDurationKey(bvid: String, cid: Long): String {
        return "progress:$bvid:$cid:duration"
    }

    /** 生成整支视频最后观看分P的 cid 存储键。 */
    private fun lastPartCidKey(bvid: String): String {
        return "last-part:$bvid:cid"
    }

    /** 生成整支视频最后观看分P序号的存储键。 */
    private fun lastPartPageKey(bvid: String): String {
        return "last-part:$bvid:page"
    }

    /** 读取当前窗口亮度与媒体音量，并转换成 Flutter 使用的 0 到 1 比例。 */
    private fun readSystemPlaybackLevels(): Map<String, Double> {
        val windowBrightness = activity.window.attributes.screenBrightness
        val brightness = if (windowBrightness >= 0f) {
            windowBrightness
        } else {
            runCatching {
                Settings.System.getInt(
                    activity.contentResolver,
                    Settings.System.SCREEN_BRIGHTNESS,
                ) / 255f
            }.getOrDefault(0.5f)
        }.coerceIn(MIN_SCREEN_BRIGHTNESS, 1f)
        val maximumVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            .coerceAtLeast(1)
        val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return mapOf(
            "brightness" to brightness.toDouble(),
            "volume" to (currentVolume.toDouble() / maximumVolume).coerceIn(0.0, 1.0),
        )
    }

    /** 只调整当前 Activity 窗口亮度，不修改用户的系统全局亮度设置。 */
    private fun setScreenBrightness(value: Float) {
        val attributes = activity.window.attributes
        attributes.screenBrightness = value.coerceIn(MIN_SCREEN_BRIGHTNESS, 1f)
        activity.window.attributes = attributes
    }

    /** 将 0 到 1 的比例换算成 Android 媒体音量等级。 */
    private fun setMediaVolume(value: Float) {
        val maximumVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            .coerceAtLeast(1)
        val targetVolume = (value.coerceIn(0f, 1f) * maximumVolume).toInt()
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, targetVolume, 0)
    }

    /** 清理播放器、系统媒体会话、纹理和未完成播放数据请求。 */
    private fun releasePlaybackResources() {
        saveCurrentPlaybackProgress(force = true)
        invalidatePlaybackRequests()
        mainHandler.removeCallbacks(stateTicker)
        unregisterPictureInPictureActionHandler()
        updateKeepScreenOn(false)
        mediaSession?.release()
        mediaSession = null
        player?.stop()
        player?.clearMediaItems()
        player?.release()
        player = null
        videoSurface?.release()
        videoSurface = null
        textureEntry?.release()
        textureEntry = null
        currentBvid = ""
        currentCid = 0L
        currentPageNumber = 1
        currentTitle = ""
        currentPartTitle = ""
        currentOwnerName = ""
        requestedQuality = DEFAULT_QUALITY
        currentQuality = DEFAULT_QUALITY
        availableQualities = listOf(
            PlaybackQualityOption(DEFAULT_QUALITY, "高清 720P"),
        )
        pendingStartPositionMs = 0L
        restoredPositionMs = 0L
        videoAspectRatio = DEFAULT_VIDEO_ASPECT_RATIO
        playbackPrepared = false
        resumeAfterPrepare = false
        resumeWhenForeground = false
        playbackDataRefreshCount = 0
        playbackSourceAttemptIndex = 0
        latestPlaybackSources = null
        clearSubtitleTrackSession()
        playbackPhase = PHASE_IDLE
        playbackMessage = null
        isInPictureInPicture = false
    }

    /** Activity 最终销毁时关闭缓存索引，已缓存内容仍留在系统可清理的缓存目录。 */
    private fun releaseMediaCache() {
        runCatching { mediaCache?.release() }
        mediaCache = null
    }

    /** 清空旧视频的内存字幕地址，防止切P或离开播放页后继续请求过期资源。 */
    private fun clearSubtitleTrackSession() {
        subtitleTrackSession = null
    }

    /** 播放时保持屏幕常亮，暂停、结束或出错后恢复系统默认行为。 */
    private fun updateKeepScreenOn(keepOn: Boolean) {
        if (keepOn) {
            activity.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            activity.window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    /** 从本应用 WebView 的 B 站会话中读取 Cookie，使登录后的播放请求复用同一状态。 */
    private fun readBilibiliCookieHeader(): String {
        return runCatching {
            CookieManager.getInstance()
                .getCookie("https://www.bilibili.com")
                .orEmpty()
        }.getOrDefault("")
    }

    /** 将 Flutter 传入的 BV 号转换为视频页 Referer，并验证格式。 */
    private fun buildVideoPageUrl(bvid: String?): String? {
        val normalized = bvid?.trim() ?: return null
        if (!BVID_PATTERN.matches(normalized)) {
            return null
        }
        return "https://www.bilibili.com/video/$normalized"
    }

    /** 仅接受 B 站 CDN 的 HTTPS 媒体地址，避免任意链接进入播放器。 */
    private fun isSafeMediaUrl(url: String): Boolean {
        val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return false
        val host = uri.host?.lowercase(Locale.ROOT) ?: return false
        return uri.scheme.equals("https", ignoreCase = true) &&
            (host.endsWith(".bilivideo.com") || host.endsWith(".bilivideo.cn"))
    }

    companion object {
        /** 供应用内画中画广播识别播放/暂停切换请求的显式 Action 名称。 */
        internal const val PICTURE_IN_PICTURE_TOGGLE_ACTION =
            "com.focubili.app.action.TOGGLE_PICTURE_IN_PICTURE_PLAYBACK"

        /** 为唯一的画中画播放按钮保留稳定请求编号，便于系统更新同一个 PendingIntent。 */
        private const val PICTURE_IN_PICTURE_TOGGLE_REQUEST_CODE = 4101

        /** 仅以弱引用保留当前控制器，避免静态广播处理器持有已销毁的 Activity。 */
        @Volatile
        private var activePictureInPictureController: WeakReference<NativePlaybackController>? = null

        /** 将画中画广播安全地分发给当前仍存在的控制器；没有播放器时直接忽略。 */
        internal fun handlePictureInPicturePlaybackToggle() {
            activePictureInPictureController?.get()?.togglePlaybackFromPictureInPicture()
        }

        private const val CHANNEL_NAME = "com.focubili.app/playback"
        private const val PHASE_IDLE = "idle"
        private const val PHASE_LOADING = "loading"
        private const val PHASE_READY = "ready"
        private const val PHASE_ENDED = "ended"
        private const val PHASE_ERROR = "error"
        private const val PROGRESS_PREFERENCES_NAME = "focubili_playback_progress"
        private const val CACHE_PREFERENCES_NAME = "focubili_media_cache_preferences"
        private const val CACHE_CAPACITY_PREFERENCE_KEY = "media_cache_capacity_bytes"
        private const val STATE_TICK_INTERVAL_MS = 500L
        private const val PROGRESS_SAVE_INTERVAL_MS = 500L
        private const val MIN_RESUME_POSITION_MS = 1L
        private const val COMPLETED_REMAINING_MS = 3_000L
        private const val NETWORK_TIMEOUT_MS = 15_000
        private const val MEDIA_CONNECT_TIMEOUT_MS = 20_000
        private const val MEDIA_READ_TIMEOUT_MS = 25_000
        private const val MEDIA_MINIMUM_RETRY_COUNT = 6
        private const val MAX_PLAYBACK_DATA_REFRESH_COUNT = 2
        /** 只检查有限层级的 cause 链，避免异常链异常循环影响播放器错误处理。 */
        private const val MAX_PLAYBACK_ERROR_CAUSE_DEPTH = 8
        /** 这些状态明确表示当前媒体地址不可继续使用，应直接刷新 playurl。 */
        private const val HTTP_STATUS_FORBIDDEN = 403
        private const val HTTP_STATUS_NOT_FOUND = 404
        private const val HTTP_STATUS_GONE = 410
        private const val BACKUP_SOURCE_RETRY_DELAY_MS = 450L
        private const val DEFAULT_TEXTURE_WIDTH = 1280
        private const val DEFAULT_TEXTURE_HEIGHT = 720
        private const val DEFAULT_QUALITY = 64
        private const val DASH_FEATURE_FLAG = 16
        private const val DEFAULT_PLAYBACK_SPEED = 1.0f
        private const val DEFAULT_VIDEO_ASPECT_RATIO = 16f / 9f
        private const val MIN_SCREEN_BRIGHTNESS = 0.01f
        private const val MIN_PLAYBACK_SPEED = 0.5f
        private const val MAX_PLAYBACK_SPEED = 2.0f
        private const val MIN_PICTURE_IN_PICTURE_ASPECT = 0.42
        private const val MAX_PICTURE_IN_PICTURE_ASPECT = 2.39
        private const val PICTURE_IN_PICTURE_RATIO_BASE = 1000
        private const val MEDIA_CACHE_DEFAULT_MAX_BYTES = 512L * 1024L * 1024L
        private const val MEDIA_CACHE_DIRECTORY_NAME = "focubili_media_cache"
        private const val PREFERRED_TRACK_SCORE = 1_000_000_000_000L
        private const val HEIGHT_SCORE_UNIT = 1_000_000L
        private const val PLAYBACK_API_HOST = "api.bilibili.com"
        private const val SUBTITLE_CDN_HOST = "aisubtitle.hdslb.com"
        private const val SUBTITLE_LOGIN_REQUIRED_CODE = -101
        private const val SUBTITLE_STATUS_AVAILABLE = "available"
        private const val SUBTITLE_STATUS_NONE = "none"
        private const val SUBTITLE_STATUS_LOGIN_REQUIRED = "login_required"
        private const val SUBTITLE_STATUS_LOCKED = "locked"
        private const val MAX_SUBTITLE_TRACKS = 20
        private const val MAX_SUBTITLE_CUES = 10_000
        private const val MAX_SUBTITLE_LABEL_CODE_POINTS = 80
        private const val MAX_SUBTITLE_CUE_CODE_POINTS = 400
        private const val MAX_SUBTITLE_TRACK_ID_LENGTH = 32
        private const val MAX_SUBTITLE_DURATION_SECONDS = 48.0 * 60.0 * 60.0
        private const val MAX_SUBTITLE_METADATA_BYTES = 1 * 1024 * 1024
        private const val MAX_SUBTITLE_DOCUMENT_BYTES = 4 * 1024 * 1024
        private const val SUBTITLE_RESPONSE_BUFFER_BYTES = 8 * 1024
        private const val DANMAKU_STATUS_AVAILABLE = "available"
        private const val DANMAKU_STATUS_NONE = "none"
        private const val MAX_DANMAKU_SEGMENT_INDEX = 1_000
        private const val MAX_DANMAKU_ENTRIES = 6_000
        private const val MAX_DANMAKU_CONTENT_CODE_POINTS = 200
        private const val MAX_DANMAKU_SEGMENT_BYTES = 6 * 1024 * 1024
        private const val DANMAKU_RESPONSE_BUFFER_BYTES = 8 * 1024
        private const val MAX_DANMAKU_PROGRESS_MS = 48L * 60L * 60L * 1_000L
        private const val DEFAULT_DANMAKU_COLOR = 0xFFFFFF
        private const val DEFAULT_DANMAKU_MODE = 1
        private const val MIN_DANMAKU_MODE = 1
        private const val MAX_DANMAKU_MODE = 9
        private const val DMSegMobileReply_ELEMS_FIELD_NUMBER = 1
        private const val DANMAKU_PROGRESS_FIELD_NUMBER = 2
        private const val DANMAKU_MODE_FIELD_NUMBER = 3
        private const val DANMAKU_COLOR_FIELD_NUMBER = 5
        private const val DANMAKU_CONTENT_FIELD_NUMBER = 7
        private const val DANMAKU_RGB_MASK = 0xFFFFFFL
        private const val PROTOBUF_WIRE_TYPE_MASK = 0x7L
        private const val PROTOBUF_VARINT_WIRE_TYPE = 0
        private const val PROTOBUF_FIXED_64_WIRE_TYPE = 1
        private const val PROTOBUF_LENGTH_DELIMITED_WIRE_TYPE = 2
        private const val PROTOBUF_FIXED_32_WIRE_TYPE = 5
        private const val PROTOBUF_FIXED_64_BYTE_COUNT = 8
        private const val PROTOBUF_FIXED_32_BYTE_COUNT = 4
        private const val MAX_PROTOBUF_VARINT_BYTES = 10
        private const val PROTOBUF_VARINT_VALUE_MASK = 0x7f
        private const val PROTOBUF_VARINT_CONTINUATION_MASK = 0x80
        private const val PROTOBUF_VARINT_SHIFT_BITS = 7
        private const val DESKTOP_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        private val BVID_PATTERN = Regex("(?i)^BV[0-9A-Za-z]{10}$")
        private val SUBTITLE_TRACK_ID_PATTERN = Regex("^[0-9]+$")
        /** 保存界面可选的全部缓存容量，避免 Flutter 与 Android 两端接受的配置不一致。 */
        private val SUPPORTED_MEDIA_CACHE_CAPACITIES = setOf(
            128L * 1024L * 1024L,
            256L * 1024L * 1024L,
            MEDIA_CACHE_DEFAULT_MAX_BYTES,
            1024L * 1024L * 1024L,
            2L * 1024L * 1024L * 1024L,
        )
    }
}
