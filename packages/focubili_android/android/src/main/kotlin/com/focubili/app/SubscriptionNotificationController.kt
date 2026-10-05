package com.focubili.app

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONException
import org.json.JSONObject

/** 前台和无界面刷新共用同一个通知通道；显示摘要不依赖 Activity。 */
class SubscriptionNotificationController(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val context = context.applicationContext
    private val channel = MethodChannel(messenger, "com.focubili.app/subscription_notifications")
    private val tapState = SubscriptionNotificationTapState()
    private var activity: Activity? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "consumeTap" -> result.success(if (activity == null) false else tapState.consume())
            "showSummary" -> {
                val rawGeneration = call.argument<Any>("generation")
                val generation = when (rawGeneration) {
                    null -> null
                    is Int -> rawGeneration.toLong()
                    is Long -> rawGeneration
                    else -> {
                        result.success(false)
                        return
                    }
                }
                result.success(
                    showSummary(
                        count = call.argument<Int>("count") ?: 0,
                        generation = generation,
                        background = call.argument<Boolean>("background") == true,
                    ),
                )
            }
            else -> result.notImplemented()
        }
    }

    /** Flutter 自动插件注册发生在 Dart 入口之前，先保留冷启动点击直到界面订阅。 */
    fun attachActivity(activity: Activity) {
        this.activity = activity
        activity.intent?.let(::handleIntent)
    }

    fun detachActivity() {
        activity = null
    }

    fun handleIntent(intent: Intent): Boolean {
        if (!intent.getBooleanExtra(TAP_EXTRA, false)) return false
        // 立即去掉一次性标记，Activity 配置重建不会再次打开更新页。
        intent.removeExtra(TAP_EXTRA)
        if (tapState.capture()) {
            channel.invokeMethod("subscriptionTapped", null)
        }
        return true
    }

    private fun showSummary(count: Int, generation: Long?, background: Boolean): Boolean {
        if (count <= 0) return false
        return try {
            if (generation == null) {
                // 独立旧版调用保留原行为；生产刷新总会提供当前 generation。
                postSummary(count)
            } else {
                withCurrentGeneration(generation, background) { postSummary(count) }
            }
        } catch (_: SQLiteException) {
            false
        } catch (_: JSONException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    /**
     * 读最新开关和发通知在同一个短原生事务中完成，与其他引擎的停用 CAS 串行。
     * 事务不跨 Dart await；即使后台 Dart 引擎被取消，finally 仍释放原生锁。
     */
    private fun withCurrentGeneration(
        generation: Long,
        background: Boolean,
        post: () -> Boolean,
    ): Boolean {
        val databaseFile = context.getDatabasePath("subscriptions_v2.db")
        if (!databaseFile.exists()) return false
        val database = SQLiteDatabase.openDatabase(
            databaseFile.absolutePath,
            null,
            SQLiteDatabase.OPEN_READWRITE,
            // Android 默认损坏处理器会删库；此只读业务检查必须保留原数据供恢复。
            DatabaseErrorHandler { },
        )
        try {
            database.beginTransaction()
            try {
                val snapshot = database.rawQuery(
                    "SELECT value FROM snapshot WHERE id = 1",
                    null,
                ).use { cursor ->
                    if (cursor.moveToFirst()) JSONObject(cursor.getString(0)) else null
                } ?: return false
                val storedGeneration = when (val value = snapshot.opt("generation")) {
                    is Int -> value.toLong()
                    is Long -> value
                    else -> null
                }
                if (!SubscriptionNotificationGenerationPolicy.isAllowed(
                        enabled = snapshot.opt("enabled") == true,
                        notificationsEnabled = snapshot.opt("notificationsEnabled") == true,
                        backgroundRefreshEnabled = snapshot.opt("backgroundRefreshEnabled") == true,
                        storedGeneration = storedGeneration,
                        expectedGeneration = generation,
                        background = background,
                    )
                ) {
                    return false
                }
                val shown = post()
                database.setTransactionSuccessful()
                return shown
            } finally {
                database.endTransaction()
            }
        } finally {
            database.close()
        }
    }

    private fun postSummary(count: Int): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "焦点订阅", NotificationManager.IMPORTANCE_LOW),
            )
            if (manager.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE) {
                return false
            }
        }
        // 按当前安装包取显式启动 Intent，同时兼容正式包和 .preview 测试包。
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            ?.putExtra(TAP_EXTRA, true)
            ?: return false
        val pending = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return try {
            manager.notify(
                NOTIFICATION_ID,
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.ic_popup_reminder)
                    .setContentTitle("焦点订阅")
                    .setContentText("发现 $count 支新视频，点击查看本机更新列表")
                    .setContentIntent(pending)
                    .setAutoCancel(true)
                    .setOnlyAlertOnce(true)
                    .build(),
            )
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun dispose() {
        detachActivity()
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val TAP_EXTRA = "focubili_subscription_tap"
        const val CHANNEL_ID = "focubili_subscription_updates"
        private const val NOTIFICATION_ID = 48108
    }
}
