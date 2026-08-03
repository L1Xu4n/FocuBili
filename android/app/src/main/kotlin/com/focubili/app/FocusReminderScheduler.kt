package com.focubili.app

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import org.json.JSONArray
import org.json.JSONObject

/** 保存一次可以跨进程和设备重启恢复的专注提醒请求。 */
data class FocusReminderRequest(
    val sessionId: String,
    val goal: String,
    val reason: String,
    val triggerAtMs: Long,
)

/** 统一负责专注提醒的系统闹钟、待办持久化和脱敏诊断事件。 */
object FocusReminderScheduler {
    private const val PREFERENCES_NAME = "focus_reminder_scheduler"
    private const val PENDING_PREFIX = "pending_"
    private const val EVENTS_KEY = "diagnostic_events"
    private const val LAST_SCHEDULED_AT_KEY = "last_scheduled_at"
    private const val LAST_TRIGGERED_AT_KEY = "last_triggered_at"
    private const val LAST_RESTORED_AT_KEY = "last_restored_at"
    private const val LAST_TRIGGER_RESULT_KEY = "last_trigger_result"
    private const val LAST_SCHEDULE_MODE_KEY = "last_schedule_mode"
    private const val MAXIMUM_DIAGNOSTIC_EVENTS = 12

    /** 安排并持久化提醒；只有系统闹钟和本机待办都成功后才返回成功。 */
    fun schedule(context: Context, request: FocusReminderRequest): Boolean {
        if (request.sessionId.isBlank() || request.triggerAtMs <= System.currentTimeMillis()) {
            recordEvent(context, "schedule", "invalid_request")
            return false
        }
        val mode = scheduleSystemAlarm(context, request, request.triggerAtMs)
        if (mode == null) {
            recordEvent(context, "schedule", "system_rejected")
            return false
        }
        if (!persistPendingRequest(context, request)) {
            cancelSystemAlarm(context, request.sessionId)
            recordEvent(context, "schedule", "storage_failed", mode)
            return false
        }
        val preferences = preferences(context)
        preferences.edit()
            .putLong(LAST_SCHEDULED_AT_KEY, System.currentTimeMillis())
            .putString(LAST_SCHEDULE_MODE_KEY, mode)
            .apply()
        recordEvent(context, "schedule", "scheduled", mode)
        return true
    }

    /** 取消指定任务的系统闹钟和待恢复记录，并保留一条脱敏诊断事件。 */
    fun cancel(context: Context, sessionId: String) {
        if (sessionId.isBlank()) return
        cancelSystemAlarm(context, sessionId)
        preferences(context).edit().remove(pendingKey(sessionId)).apply()
        recordEvent(context, "cancel", "cancelled")
    }

    /** 系统闹钟到达后删除一次性待办，并记录通知最终是否成功发布。 */
    fun markTriggered(context: Context, sessionId: String, result: String) {
        if (sessionId.isNotBlank()) {
            preferences(context).edit().remove(pendingKey(sessionId)).apply()
        }
        preferences(context).edit()
            .putLong(LAST_TRIGGERED_AT_KEY, System.currentTimeMillis())
            .putString(LAST_TRIGGER_RESULT_KEY, result)
            .apply()
        recordEvent(context, "trigger", result)
    }

    /** 在开机、应用升级或重新取得精确闹钟权限后重建所有尚未到期的提醒。 */
    fun restorePending(context: Context, source: String): Int {
        val requests = loadPendingRequests(context)
        if (requests.isEmpty()) {
            recordEvent(context, "restore", "nothing_pending", source)
            return 0
        }
        val now = System.currentTimeMillis()
        var restored = 0
        for (request in requests) {
            val safeTriggerAt = if (request.triggerAtMs > now) {
                request.triggerAtMs
            } else {
                now + 1_500L
            }
            if (scheduleSystemAlarm(context, request, safeTriggerAt) != null) {
                restored += 1
            }
        }
        preferences(context).edit()
            .putLong(LAST_RESTORED_AT_KEY, now)
            .apply()
        recordEvent(context, "restore", "restored_$restored", source)
        return restored
    }

    /** 返回诊断页需要的脱敏闹钟状态，不包含任务目标、原因或会话编号。 */
    fun diagnostics(context: Context): Map<String, Any> {
        val preferences = preferences(context)
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return mapOf(
            "pendingCount" to loadPendingRequests(context).size,
            "lastScheduledAtMs" to preferences.getLong(LAST_SCHEDULED_AT_KEY, 0L),
            "lastTriggeredAtMs" to preferences.getLong(LAST_TRIGGERED_AT_KEY, 0L),
            "lastRestoredAtMs" to preferences.getLong(LAST_RESTORED_AT_KEY, 0L),
            "lastTriggerResult" to preferences.getString(LAST_TRIGGER_RESULT_KEY, "never").orEmpty(),
            "lastScheduleMode" to preferences.getString(LAST_SCHEDULE_MODE_KEY, "never").orEmpty(),
            "exactAlarmAllowed" to canScheduleExact(context),
            "notificationsEnabled" to notificationManager.areNotificationsEnabled(),
            "batteryOptimizationIgnored" to powerManager.isIgnoringBatteryOptimizations(context.packageName),
            "backgroundRestricted" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                activityManager.isBackgroundRestricted
            } else {
                false
            },
            "manufacturer" to Build.MANUFACTURER.orEmpty(),
            "events" to readDiagnosticEvents(context),
        )
    }

    /** 只清除闹钟诊断事件与时间戳，绝不删除仍在等待的真实提醒。 */
    fun clearDiagnostics(context: Context) {
        preferences(context).edit()
            .remove(EVENTS_KEY)
            .remove(LAST_SCHEDULED_AT_KEY)
            .remove(LAST_TRIGGERED_AT_KEY)
            .remove(LAST_RESTORED_AT_KEY)
            .remove(LAST_TRIGGER_RESULT_KEY)
            .remove(LAST_SCHEDULE_MODE_KEY)
            .apply()
    }

    /** 构建稳定且不可变的广播 PendingIntent，确保进程退出后系统仍可启动接收器。 */
    fun reminderPendingIntent(
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

    /** 把一条提醒交给 AlarmManager；返回 exact 或 inexact，异常时返回空。 */
    private fun scheduleSystemAlarm(
        context: Context,
        request: FocusReminderRequest,
        triggerAtMs: Long,
    ): String? {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pendingIntent = reminderPendingIntent(
            context,
            request.sessionId,
            request.goal,
            request.reason,
        )
        return try {
            if (canScheduleExact(context)) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMs,
                    pendingIntent,
                )
                "exact"
            } else {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMs,
                    pendingIntent,
                )
                "inexact"
            }
        } catch (_: SecurityException) {
            try {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMs,
                    pendingIntent,
                )
                "inexact"
            } catch (_: RuntimeException) {
                null
            }
        } catch (_: RuntimeException) {
            null
        }
    }

    /** 从 AlarmManager 移除与任务编号匹配的广播闹钟。 */
    private fun cancelSystemAlarm(context: Context, sessionId: String) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pendingIntent = reminderPendingIntent(context, sessionId, "", "")
        alarmManager.cancel(pendingIntent)
        pendingIntent.cancel()
    }

    /** 检查当前系统是否允许本应用安排精确闹钟。 */
    private fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return alarmManager.canScheduleExactAlarms()
    }

    /** 将一条待提醒请求保存为私有 JSON；这些正文不会进入复制诊断文本。 */
    private fun persistPendingRequest(context: Context, request: FocusReminderRequest): Boolean {
        val json = JSONObject()
            .put("sessionId", request.sessionId)
            .put("goal", request.goal)
            .put("reason", request.reason)
            .put("triggerAtMs", request.triggerAtMs)
        return preferences(context).edit()
            .putString(pendingKey(request.sessionId), json.toString())
            .commit()
    }

    /** 读取所有仍待发送的提醒；单条数据损坏时忽略该条而不影响其他闹钟。 */
    private fun loadPendingRequests(context: Context): List<FocusReminderRequest> {
        val requests = mutableListOf<FocusReminderRequest>()
        for ((key, value) in preferences(context).all) {
            if (!key.startsWith(PENDING_PREFIX) || value !is String) continue
            try {
                val json = JSONObject(value)
                val sessionId = json.optString("sessionId").trim()
                val triggerAtMs = json.optLong("triggerAtMs", 0L)
                if (sessionId.isBlank() || triggerAtMs <= 0L) continue
                requests += FocusReminderRequest(
                    sessionId = sessionId,
                    goal = json.optString("goal"),
                    reason = json.optString("reason"),
                    triggerAtMs = triggerAtMs,
                )
            } catch (_: RuntimeException) {
                // 单条旧数据损坏时跳过，避免设备启动广播因此失败。
            }
        }
        return requests.sortedBy { request -> request.triggerAtMs }
    }

    /** 追加一条不含用户内容的闹钟诊断事件，并限制最多保存十二条。 */
    private fun recordEvent(context: Context, type: String, result: String, mode: String = "") {
        val existing = try {
            val savedEvents = preferences(context).getString(EVENTS_KEY, "[]").orEmpty()
            JSONArray(savedEvents.ifBlank { "[]" })
        } catch (_: RuntimeException) {
            JSONArray()
        }
        val next = JSONArray().put(
            JSONObject()
                .put("timeMs", System.currentTimeMillis())
                .put("type", type)
                .put("result", result)
                .put("mode", mode),
        )
        val limit = minOf(existing.length(), MAXIMUM_DIAGNOSTIC_EVENTS - 1)
        for (index in 0 until limit) {
            next.put(existing.opt(index))
        }
        preferences(context).edit().putString(EVENTS_KEY, next.toString()).apply()
    }

    /** 把本机 JSON 事件转换为 MethodChannel 可传输的简单字典列表。 */
    private fun readDiagnosticEvents(context: Context): List<Map<String, Any>> {
        val events = try {
            val savedEvents = preferences(context).getString(EVENTS_KEY, "[]").orEmpty()
            JSONArray(savedEvents.ifBlank { "[]" })
        } catch (_: RuntimeException) {
            JSONArray()
        }
        val values = mutableListOf<Map<String, Any>>()
        for (index in 0 until minOf(events.length(), MAXIMUM_DIAGNOSTIC_EVENTS)) {
            val event = events.optJSONObject(index) ?: continue
            values += mapOf(
                "timeMs" to event.optLong("timeMs", 0L),
                "type" to event.optString("type", "unknown"),
                "result" to event.optString("result", "unknown"),
                "mode" to event.optString("mode", ""),
            )
        }
        return values
    }

    /** 返回专注提醒私有偏好设置实例。 */
    private fun preferences(context: Context) =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    /** 使用任务编号生成不会与诊断字段冲突的待提醒键名。 */
    private fun pendingKey(sessionId: String) = "$PENDING_PREFIX$sessionId"
}
