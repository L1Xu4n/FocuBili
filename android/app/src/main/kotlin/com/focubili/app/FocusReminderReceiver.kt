package com.focubili.app

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/** 在系统闹钟触发后显示“继续专注”本地通知。 */
class FocusReminderReceiver : BroadcastReceiver() {
    /** 校验通知权限并展示一条可打开应用的提醒。 */
    override fun onReceive(context: Context, intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        FocusNotificationController.createNotificationChannel(context)
        val sessionId = intent.getStringExtra("sessionId").orEmpty()
        val goal = intent.getStringExtra("goal").orEmpty().ifBlank { "未结束的专注任务" }
        val openAppIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openAppPendingIntent = PendingIntent.getActivity(
            context,
            sessionId.hashCode(),
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, FocusNotificationController.NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }.setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle("该继续专注了")
            .setContentText(goal)
            .setStyle(Notification.BigTextStyle().bigText("打开视频，继续：$goal"))
            .setAutoCancel(true)
            .setContentIntent(openAppPendingIntent)
            .build()
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(sessionId.hashCode(), notification)
    }
}
