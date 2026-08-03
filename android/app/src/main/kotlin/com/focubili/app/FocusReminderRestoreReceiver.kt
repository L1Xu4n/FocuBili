package com.focubili.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 在系统重启、应用升级或精确闹钟权限恢复后重新安排尚未到期的专注提醒。 */
class FocusReminderRestoreReceiver : BroadcastReceiver() {
    /** 接收系统受保护广播，并用广播动作作为脱敏诊断来源恢复闹钟。 */
    override fun onReceive(context: Context, intent: Intent) {
        val source = when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> "boot"
            Intent.ACTION_MY_PACKAGE_REPLACED -> "package_replaced"
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED" -> "exact_permission"
            else -> "system"
        }
        FocusReminderScheduler.restorePending(context, source)
    }
}
