package com.focubili.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Only immediate summaries of foreground refreshes. No scheduling or background polling. */
class SubscriptionNotificationController(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.focubili.app/subscription_notifications")
    private var initialTap = activity.intent?.getBooleanExtra(TAP_EXTRA, false) == true

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consumeTap" -> {
                val tapped = initialTap
                initialTap = false
                activity.intent?.removeExtra(TAP_EXTRA)
                result.success(tapped)
            }
            "showSummary" -> result.success(showSummary(call.argument<Int>("count") ?: 0))
            else -> result.notImplemented()
        }
    }
    fun handleIntent(intent: Intent) {
        if (intent.getBooleanExtra(TAP_EXTRA, false)) {
            intent.removeExtra(TAP_EXTRA)
            initialTap = false
            channel.invokeMethod("subscriptionTapped", null)
        }
    }
    private fun showSummary(count: Int): Boolean {
        if (count <= 0) return false
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return false
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "订阅更新", NotificationManager.IMPORTANCE_LOW),
        )
        val intent = Intent(activity, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(TAP_EXTRA, true)
        val pending = PendingIntent.getActivity(activity, 48108, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return try {
            manager.notify(48108, NotificationCompat.Builder(activity, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_popup_reminder)
                .setContentTitle("订阅更新")
                .setContentText("发现 $count 支新视频，点击查看本机更新列表")
                .setContentIntent(pending).setAutoCancel(true).setOnlyAlertOnce(true).build())
            true
        } catch (_: SecurityException) { false }
    }
    fun dispose() { channel.setMethodCallHandler(null) }
    companion object {
        const val TAP_EXTRA = "focubili_subscription_tap"
        const val CHANNEL_ID = "focubili_subscription_updates"
    }
}
