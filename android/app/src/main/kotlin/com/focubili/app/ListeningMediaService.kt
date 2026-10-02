package com.focubili.app

import android.content.Context
import android.content.Intent
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/** 在听视频期间将当前媒体会话托管给前台媒体服务，提供锁屏和通知栏控制。 */
@UnstableApi
class ListeningMediaService : MediaSessionService() {
    private var hostedSession: MediaSession? = null

    /** 服务创建时接入已准备的唯一会话，由 Media3 管理媒体通知与前台状态。 */
    override fun onCreate() {
        super.onCreate()
        hostedSession = pendingSession
        hostedSession?.let(::addSession)
        if (hostedSession == null) stopSelf()
    }

    /** 只向系统媒体控制器提供现有会话，不接受外部提供的媒体地址。 */
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = hostedSession

    /** 快速关闭再开启或换播放页时同步新会话，避免仍托管已经释放的旧播放器。 */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (hostedSession !== pendingSession) {
            detachHostedSession()
            hostedSession = pendingSession
            hostedSession?.let(::addSession)
        }
        if (hostedSession == null) stopSelf()
        return super.onStartCommand(intent, flags, startId)
    }

    /** 用户从最近任务关闭应用时停止听视频，避免无界面遗留播放。 */
    override fun onTaskRemoved(rootIntent: Intent?) {
        hostedSession?.player?.pause()
        stopSelf()
    }

    /** 撤销托管；播放器由播放页的显式退出流程统一释放，切回视频仍可复用。 */
    override fun onDestroy() {
        detachHostedSession()
        super.onDestroy()
    }

    /** 已释放会话会被 Media3 自动移除，只撤销仍登记的会话，避免退出时重复移除崩溃。 */
    private fun detachHostedSession() {
        val previous = hostedSession
        hostedSession = null
        if (previous != null && sessions.contains(previous)) {
            removeSession(previous)
        }
    }

    companion object {
        private var pendingSession: MediaSession? = null

        /** 从前台用户操作启动服务；会话保留系统标题、耳机控制和音频焦点策略。 */
        fun start(context: Context, session: MediaSession) {
            pendingSession = session
            context.startService(Intent(context, ListeningMediaService::class.java))
        }

        /** 退出听视频或播放页时移除服务与会话引用。 */
        fun stop(context: Context) {
            pendingSession = null
            context.stopService(Intent(context, ListeningMediaService::class.java))
        }
    }
}
