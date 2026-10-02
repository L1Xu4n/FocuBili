package com.focubili.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/** Keeps active Dart transfers visible to Android as user-initiated data sync. */
class DownloadProgressService : Service() {
    companion object {
        const val CHANNEL = "offline_downloads"
        const val NOTIFICATION_ID = 15119
        var onTransferTimeout: (() -> Unit)? = null
    }

    /** Creates a quiet progress channel once on supported Android versions. */
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "离线下载", NotificationManager.IMPORTANCE_LOW),
            )
        }
    }

    /** Updates one ongoing notification without sound or repeated popups. */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val open = Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(this, 15119, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            Notification.Builder(this)
        }
        val progress = intent.getIntExtra("progress", -1)
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(intent.getStringExtra("title") ?: "离线缓存")
            .setContentText(intent.getStringExtra("status") ?: "正在下载")
            .setContentIntent(pending)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setProgress(100, progress.coerceAtLeast(0), progress < 0)
            .build()
        startForeground(NOTIFICATION_ID, notification)
        return START_NOT_STICKY
    }

    /** Exposes no binder or control surface to other applications. */
    override fun onBind(intent: Intent?): IBinder? = null

    /** Stops within Android 15's dataSync timeout and asks Dart to persist pauses. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        onTransferTimeout?.invoke()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** Removes stale progress when Android tears down the service. */
    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
