package com.focubili.app

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Rational
import android.view.Surface
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
import java.io.File
import java.net.URL
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection

/**
 * 直接请求公开视频播放数据，并把唯一的 Media3 播放器输出为 Flutter Texture。
 *
 * 播放器同时负责倍速、清晰度切换、本地进度记忆和 Android 系统媒体会话。
 */
@OptIn(UnstableApi::class)
class NativePlaybackController(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val renderer: FlutterRenderer,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val playbackRequestExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val progressPreferences = activity.getSharedPreferences(
        PROGRESS_PREFERENCES_NAME,
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

    /** 保存一档可供 Flutter 选择的清晰度编号与名称。 */
    private data class PlaybackQualityOption(
        val id: Int,
        val label: String,
    )

    /** 保存一组已验证的 DASH 主备地址、实际清晰度和媒体请求信息。 */
    private data class PlaybackSources(
        val videoUrls: List<String>,
        val audioUrls: List<String>,
        val referer: String,
        val actualQuality: Int,
        val qualities: List<PlaybackQualityOption>,
    )

    /** 表示播放数据服务返回了可向用户说明的预期错误。 */
    private class PlaybackSourceException(message: String) : Exception(message)

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
        channel.setMethodCallHandler(null)
    }

    /** Android 画中画状态变化时同步给 Flutter，以隐藏小窗中的非视频控件。 */
    fun onPictureInPictureModeChanged(inPictureInPicture: Boolean) {
        isInPictureInPicture = inPictureInPicture
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
        val safeAspectRatio = requestedAspectRatio
            .takeIf { ratio -> ratio.isFinite() && ratio > 0.0 }
            ?.coerceIn(MIN_PICTURE_IN_PICTURE_ASPECT, MAX_PICTURE_IN_PICTURE_ASPECT)
            ?: DEFAULT_VIDEO_ASPECT_RATIO.toDouble()
        val paramsBuilder = PictureInPictureParams.Builder()
            .setAspectRatio(
                Rational(
                    (safeAspectRatio * PICTURE_IN_PICTURE_RATIO_BASE).toInt(),
                    PICTURE_IN_PICTURE_RATIO_BASE,
                ),
            )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            paramsBuilder.setSeamlessResizeEnabled(true)
        }
        val entered = runCatching {
            activity.enterPictureInPictureMode(paramsBuilder.build())
        }.getOrDefault(false)
        result.success(entered)
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
        if (currentBvid.isEmpty() || currentCid <= 0L) {
            reportError("原生播放器无法播放该视频：${error.errorCodeName}")
            return
        }
        pendingStartPositionMs = nativePlayer.currentPosition.coerceAtLeast(0L)
        resumeAfterPrepare = nativePlayer.playWhenReady || resumeAfterPrepare
        playbackPrepared = false
        val sources = latestPlaybackSources
        val candidateCount = sources?.let(::playbackCandidateCount) ?: 0
        val nextCandidateIndex = playbackSourceAttemptIndex + 1
        if (sources != null && nextCandidateIndex < candidateCount) {
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
            playbackMessage = "播放线路已失效，正在刷新播放数据…"
            emitPlaybackState()
            requestPlaybackSources(currentBvid, currentCid, requestedQuality)
            return
        }
        reportError("原生播放器多次重试后仍无法播放：${error.errorCodeName}")
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
        val videoUrls = selectMediaUrls(dash.optJSONArray("video"), actualQuality)
        val audioUrls = selectMediaUrls(dash.optJSONArray("audio"))
        if (videoUrls.isEmpty()) {
            throw PlaybackSourceException("播放数据没有返回安全的视频地址。")
        }
        val referer = buildVideoPageUrl(bvid)
            ?: throw PlaybackSourceException("无法生成视频页面地址。")
        return PlaybackSources(
            videoUrls = videoUrls,
            audioUrls = audioUrls,
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

    /** 从一组 DASH 轨道中选择目标质量，并保留该轨道的主地址与全部安全备用地址。 */
    private fun selectMediaUrls(
        mediaItems: JSONArray?,
        preferredId: Int? = null,
    ): List<String> {
        if (mediaItems == null) {
            return emptyList()
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
            val heightScore = media.optInt("height").coerceAtLeast(0).toLong() * HEIGHT_SCORE_UNIT
            val bandwidthScore = media.optLong("bandwidth").coerceAtLeast(0L)
            val score = qualityBonus + heightScore + bandwidthScore
            if (score > bestScore) {
                selectedMedia = media
                bestScore = score
            }
        }
        return selectedMedia?.let(::readMediaUrls) ?: emptyList()
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

    /** 延迟创建最大 512MB 的 LRU 视频缓存，容量满后自动删除最久未使用的数据。 */
    private fun ensureMediaCache(): SimpleCache {
        mediaCache?.let { cache -> return cache }
        val cacheDirectory = File(activity.cacheDir, MEDIA_CACHE_DIRECTORY_NAME)
        val cache = SimpleCache(
            cacheDirectory,
            LeastRecentlyUsedCacheEvictor(MEDIA_CACHE_MAX_BYTES),
            cacheDatabaseProvider,
        )
        mediaCache = cache
        return cache
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
            .setCustomCacheKey("$currentBvid:$currentCid:$currentQuality:video")
            .setMediaMetadata(mediaMetadata)
            .build()
        val videoSource = sourceFactory.createMediaSource(videoItem)
        val finalSource: MediaSource = if (isSafeMediaUrl(audioUrl)) {
            val audioSource = sourceFactory.createMediaSource(
                MediaItem.Builder()
                    .setUri(audioUrl)
                    .setCustomCacheKey("$currentBvid:$currentCid:$currentQuality:audio")
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
        playbackPhase = PHASE_IDLE
        playbackMessage = null
        isInPictureInPicture = false
    }

    /** Activity 最终销毁时关闭缓存索引，已缓存内容仍留在系统可清理的缓存目录。 */
    private fun releaseMediaCache() {
        runCatching { mediaCache?.release() }
        mediaCache = null
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
        private const val CHANNEL_NAME = "com.focubili.app/playback"
        private const val PHASE_IDLE = "idle"
        private const val PHASE_LOADING = "loading"
        private const val PHASE_READY = "ready"
        private const val PHASE_ENDED = "ended"
        private const val PHASE_ERROR = "error"
        private const val PROGRESS_PREFERENCES_NAME = "focubili_playback_progress"
        private const val STATE_TICK_INTERVAL_MS = 500L
        private const val PROGRESS_SAVE_INTERVAL_MS = 500L
        private const val MIN_RESUME_POSITION_MS = 1L
        private const val COMPLETED_REMAINING_MS = 3_000L
        private const val NETWORK_TIMEOUT_MS = 15_000
        private const val MEDIA_CONNECT_TIMEOUT_MS = 20_000
        private const val MEDIA_READ_TIMEOUT_MS = 25_000
        private const val MEDIA_MINIMUM_RETRY_COUNT = 6
        private const val MAX_PLAYBACK_DATA_REFRESH_COUNT = 2
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
        private const val MEDIA_CACHE_MAX_BYTES = 512L * 1024L * 1024L
        private const val MEDIA_CACHE_DIRECTORY_NAME = "focubili_media_cache"
        private const val PREFERRED_TRACK_SCORE = 1_000_000_000_000L
        private const val HEIGHT_SCORE_UNIT = 1_000_000L
        private const val PLAYBACK_API_HOST = "api.bilibili.com"
        private const val DESKTOP_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        private val BVID_PATTERN = Regex("(?i)^BV[0-9A-Za-z]{10}$")
    }
}
