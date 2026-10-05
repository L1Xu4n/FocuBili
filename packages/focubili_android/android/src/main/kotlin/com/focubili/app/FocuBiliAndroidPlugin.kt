package com.focubili.app

import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry

/**
 * 同时注册前台和 Workmanager 无界面引擎需要的通道。
 *
 * 会话仍只来自 Android WebView 的原有沙箱；后台引擎不依赖 Activity、
 * 不启动播放器或前台服务，也不会请求运行时通知权限。
 */
class FocuBiliAndroidPlugin : FlutterPlugin, ActivityAware, PluginRegistry.NewIntentListener {
    private var cookieController: BilibiliCookieController? = null
    private var notificationController: SubscriptionNotificationController? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cookieController = BilibiliCookieController(binding.binaryMessenger)
        notificationController = SubscriptionNotificationController(
            binding.applicationContext,
            binding.binaryMessenger,
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        cookieController?.dispose()
        cookieController = null
        notificationController?.dispose()
        notificationController = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        notificationController?.attachActivity(binding.activity)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        notificationController?.detachActivity()
    }

    override fun onNewIntent(intent: Intent): Boolean {
        return notificationController?.handleIntent(intent) == true
    }
}
