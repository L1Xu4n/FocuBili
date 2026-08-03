package com.focubili.app

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.PowerManager
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
            "hasExactAlarmPermission" -> result.success(hasExactAlarmPermission())
            "openExactAlarmSettings" -> {
                openExactAlarmSettings()
                result.success(null)
            }
            "hasDoNotDisturbAccess" -> result.success(hasDoNotDisturbAccess())
            "openDoNotDisturbSettings" -> {
                openDoNotDisturbSettings()
                result.success(null)
            }
            "setFocusDoNotDisturb" -> result.success(
                setFocusDoNotDisturb(call.argument<Boolean>("enabled") == true),
            )
            "getPermissionOverview" -> result.success(buildPermissionOverview())
            "openBackgroundAutostartSettings" -> {
                openBackgroundAutostartSettings()
                result.success(null)
            }
            "openBatterySettings" -> {
                openApplicationDetailsSettings()
                result.success(null)
            }
            "getReminderDiagnostics" -> result.success(
                FocusReminderScheduler.diagnostics(activity),
            )
            "clearReminderDiagnostics" -> {
                FocusReminderScheduler.clearDiagnostics(activity)
                result.success(null)
            }
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

    /** 同时检查 Android 13 运行时权限与系统中的应用级通知总开关。 */
    private fun hasNotificationPermission(): Boolean {
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) return false
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
    }

    /** 请求 Android 13 通知权限，并暂存 Flutter 回调等待系统结果。 */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(hasNotificationPermission())
            return
        }
        val runtimePermissionGranted = ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (runtimePermissionGranted) {
            result.success(hasNotificationPermission())
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

    /** 汇总统一权限页需要的公开状态；小米后台自启动只能标记为需要用户手动确认。 */
    private fun buildPermissionOverview(): Map<String, Any> {
        val powerManager = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        val activityManager = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return mapOf(
            "notificationAllowed" to hasNotificationPermission(),
            "exactAlarmAllowed" to hasExactAlarmPermission(),
            "doNotDisturbAllowed" to hasDoNotDisturbAccess(),
            "batteryOptimizationIgnored" to powerManager.isIgnoringBatteryOptimizations(
                activity.packageName,
            ),
            "backgroundRestricted" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                activityManager.isBackgroundRestricted
            } else {
                false
            },
            "requiresAutostartGuide" to isXiaomiFamilyDevice(),
            "manufacturer" to Build.MANUFACTURER.orEmpty(),
            "apiLevel" to Build.VERSION.SDK_INT,
        )
    }

    /** 检查 Android 12 及以上“闹钟和提醒”特殊访问权限；旧系统无需额外授权。 */
    private fun hasExactAlarmPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarmManager = activity.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return alarmManager.canScheduleExactAlarms()
    }

    /** 打开当前应用的精确闹钟特殊访问页，系统不支持专用页面时回退应用详情。 */
    private fun openExactAlarmSettings() {
        val packageUri = Uri.parse("package:${activity.packageName}")
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, packageUri)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
        }
        try {
            activity.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            activity.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri),
            )
        }
    }

    /** 打开小米后台自启动管理；其他系统或入口缺失时安全回退到应用详情页。 */
    private fun openBackgroundAutostartSettings() {
        val intents = listOf(
            Intent().setComponent(
                ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity",
                ),
            ),
            Intent("miui.intent.action.OP_AUTO_START").addCategory(Intent.CATEGORY_DEFAULT),
        )
        for (intent in intents) {
            try {
                activity.startActivity(intent)
                return
            } catch (_: ActivityNotFoundException) {
                // 当前 HyperOS 版本没有这个入口时继续尝试下一个系统页面。
            } catch (_: SecurityException) {
                // 厂商限制第三方直达时回退到应用详情页，由用户手动进入权限管理。
            }
        }
        openApplicationDetailsSettings()
    }

    /** 打开当前应用详情页，通知、电量和取消权限都可以由用户在这里统一管理。 */
    private fun openApplicationDetailsSettings() {
        val packageUri = Uri.parse("package:${activity.packageName}")
        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
    }

    /** 判断当前设备是否属于需要额外后台自启动授权的小米、Redmi 或 POCO 系列。 */
    private fun isXiaomiFamilyDevice(): Boolean {
        val identity = "${Build.MANUFACTURER} ${Build.BRAND}".lowercase()
        return identity.contains("xiaomi") ||
            identity.contains("redmi") ||
            identity.contains("poco")
    }

    /** 检查应用是否获准修改 Android 勿扰模式；此权限只能由用户在系统特殊访问页授予。 */
    private fun hasDoNotDisturbAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return manager.isNotificationPolicyAccessGranted
    }

    /** 打开 Android 勿扰模式特殊访问页面，让用户明确决定是否授权。 */
    private fun openDoNotDisturbSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
        } else {
            Intent(Settings.ACTION_SETTINGS)
        }
        activity.startActivity(intent)
    }

    /** 专注开始时进入优先级勿扰，结束时恢复用户进入专注前的系统过滤状态。 */
    private fun setFocusDoNotDisturb(enabled: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.isNotificationPolicyAccessGranted) return false
        val preferences = activity.getSharedPreferences(DND_PREFERENCES, Context.MODE_PRIVATE)
        val focusDndActive = preferences.getBoolean(DND_ACTIVE_KEY, false)
        if (enabled) {
            if (focusDndActive &&
                manager.currentInterruptionFilter == NotificationManager.INTERRUPTION_FILTER_PRIORITY
            ) return true
            if (!focusDndActive) {
                preferences.edit()
                    .putInt(DND_PREVIOUS_FILTER_KEY, manager.currentInterruptionFilter)
                    .putBoolean(DND_ACTIVE_KEY, true)
                    .apply()
            }
            manager.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_PRIORITY)
            return true
        }
        if (!focusDndActive) return true
        val previousFilter = preferences.getInt(
            DND_PREVIOUS_FILTER_KEY,
            NotificationManager.INTERRUPTION_FILTER_ALL,
        )
        manager.setInterruptionFilter(previousFilter)
        preferences.edit()
            .remove(DND_PREVIOUS_FILTER_KEY)
            .remove(DND_ACTIVE_KEY)
            .apply()
        return true
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

    /** 使用系统后台闹钟安排提醒；能使用精确闹钟时准点触发，否则保留待机唤醒回退。 */
    private fun scheduleReminder(call: MethodCall): Boolean {
        if (!hasNotificationPermission()) return false
        val sessionId = call.argument<String>("sessionId").orEmpty()
        val goal = call.argument<String>("goal").orEmpty()
        val reason = call.argument<String>("reason").orEmpty()
        val triggerAtMs = call.argument<Number>("triggerAtMs")?.toLong() ?: return false
        return FocusReminderScheduler.schedule(
            activity,
            FocusReminderRequest(
                sessionId = sessionId,
                goal = goal,
                reason = reason,
                triggerAtMs = triggerAtMs,
            ),
        )
    }

    /** 取消同一任务编号对应的待发送提醒。 */
    private fun cancelReminder(sessionId: String) {
        FocusReminderScheduler.cancel(activity, sessionId)
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
        private const val DND_PREFERENCES = "focus_do_not_disturb"
        private const val DND_ACTIVE_KEY = "active"
        private const val DND_PREVIOUS_FILTER_KEY = "previous_filter"

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

    }
}
