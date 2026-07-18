package com.focubili.app

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** 处理 Flutter 发来的通知权限、设置跳转和专注提醒安排请求。 */
class FocusNotificationController(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var celebrationPlayer: MediaPlayer? = null

    /** 创建通知通道并开始监听 Flutter 方法调用。 */
    init {
        createNotificationChannel(activity)
        channel.setMethodCallHandler(this)
    }

    /** 根据方法名执行权限、系统设置、安排提醒或取消提醒。 */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasNotificationPermission())
            "requestPermission" -> requestNotificationPermission(result)
            "openSettings" -> {
                openNotificationSettings()
                result.success(null)
            }
            "scheduleReminder" -> result.success(scheduleReminder(call))
            "playCelebrationSound" -> {
                playCelebrationSound()
                result.success(null)
            }
            "cancelReminder" -> {
                cancelReminder(call.argument<String>("sessionId").orEmpty())
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** 检查 Android 13 运行时权限；旧系统只检查应用级通知开关。 */
    private fun hasNotificationPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    /** 请求 Android 13 通知权限，并暂存 Flutter 回调等待系统结果。 */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (hasNotificationPermission() || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_in_progress", "通知权限请求正在进行", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST_CODE,
        )
    }

    /** 接收 Activity 转发的权限结果并完成对应 Flutter Future。 */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
        return true
    }

    /** 打开当前应用通知设置页，用户可在拒绝后手动启用。 */
    private fun openNotificationSettings() {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
            data = Uri.parse("package:${activity.packageName}")
        }
        activity.startActivity(intent)
    }

    /** 播放用户提供并打包在应用内的完成音效，重复触发时先释放旧播放器。 */
    private fun playCelebrationSound() {
        celebrationPlayer?.release()
        celebrationPlayer = MediaPlayer.create(activity, R.raw.focus_complete)?.also { player ->
            player.setOnCompletionListener { completedPlayer ->
                if (celebrationPlayer === completedPlayer) {
                    celebrationPlayer = null
                }
                completedPlayer.release()
            }
            player.setOnErrorListener { failedPlayer, _, _ ->
                if (celebrationPlayer === failedPlayer) {
                    celebrationPlayer = null
                }
                failedPlayer.release()
                true
            }
            player.start()
        }
    }

    /** 使用允许待机唤醒的非精确闹钟安排用户选定时间的提醒。 */
    private fun scheduleReminder(call: MethodCall): Boolean {
        if (!hasNotificationPermission()) return false
        val sessionId = call.argument<String>("sessionId").orEmpty()
        val goal = call.argument<String>("goal").orEmpty()
        val reason = call.argument<String>("reason").orEmpty()
        val triggerAtMs = call.argument<Number>("triggerAtMs")?.toLong() ?: return false
        if (sessionId.isBlank() || triggerAtMs <= System.currentTimeMillis()) return false
        val alarmManager = activity.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerAtMs,
            reminderPendingIntent(activity, sessionId, goal, reason),
        )
        return true
    }

    /** 取消同一任务编号对应的待发送提醒。 */
    private fun cancelReminder(sessionId: String) {
        if (sessionId.isBlank()) return
        val alarmManager = activity.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(reminderPendingIntent(activity, sessionId, "", ""))
    }

    /** 解除方法通道和未完成权限回调，防止 Activity 销毁后继续持有引用。 */
    fun dispose() {
        channel.setMethodCallHandler(null)
        celebrationPlayer?.release()
        celebrationPlayer = null
        pendingPermissionResult?.error("activity_destroyed", "页面已关闭", null)
        pendingPermissionResult = null
    }

    companion object {
        const val CHANNEL_NAME = "com.focubili.app/focus_notifications"
        const val NOTIFICATION_CHANNEL_ID = "focus_reminders"
        private const val PERMISSION_REQUEST_CODE = 7041

        /** 在 Android 8 及以上创建用户可管理的“专注提醒”通知通道。 */
        fun createNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "专注提醒",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "提醒继续尚未结束的专注任务"
            }
            manager.createNotificationChannel(channel)
        }

        /** 使用稳定请求码构建可被安排和取消的广播 PendingIntent。 */
        private fun reminderPendingIntent(
            context: Context,
            sessionId: String,
            goal: String,
            reason: String,
        ): PendingIntent {
            val intent = Intent(context, FocusReminderReceiver::class.java).apply {
                putExtra("sessionId", sessionId)
                putExtra("goal", goal)
                putExtra("reason", reason)
            }
            return PendingIntent.getBroadcast(
                context,
                sessionId.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
