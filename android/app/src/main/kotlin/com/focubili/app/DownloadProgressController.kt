package com.focubili.app

import android.app.Activity
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Bridges throttled queue snapshots to the foreground download notification. */
class DownloadProgressController(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.focubili.app/downloads")

    init {
        DownloadProgressService.onTransferTimeout = { channel.invokeMethod("pauseAll", null) }
        channel.setMethodCallHandler { call, result ->
            if (call.method != "update") {
                result.notImplemented()
            } else {
                try {
                    val intent = Intent(activity, DownloadProgressService::class.java)
                    if (call.argument<Boolean>("active") == true) {
                        intent.putExtra("title", call.argument<String>("title"))
                        intent.putExtra("status", call.argument<String>("status"))
                        intent.putExtra("progress", call.argument<Int>("progress") ?: -1)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            activity.startForegroundService(intent)
                        } else {
                            activity.startService(intent)
                        }
                    } else {
                        activity.stopService(intent)
                    }
                    result.success(null)
                } catch (error: Exception) {
                    result.error("download_notification", "下载通知不可用", null)
                }
            }
        }
    }

    /** Disconnects callbacks and removes the notification when the engine is gone. */
    fun dispose() {
        DownloadProgressService.onTransferTimeout = null
        channel.setMethodCallHandler(null)
        activity.stopService(Intent(activity, DownloadProgressService::class.java))
    }
}
