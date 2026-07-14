package com.focubili.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 向 Flutter 提供无需权限的设备状态，只读取系统公开的当前电量百分比。
 *
 * 控制器不持有 Flutter 页面、账号或播放器数据，因此读取失败时也不会影响播放。
 */
class DeviceStatusController(
    activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val applicationContext = activity.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler(this)
    }

    /** 分发 Flutter 的设备状态查询，未知方法明确返回未实现。 */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_GET_BATTERY_PERCENT -> result.success(readBatteryPercent())
            else -> result.notImplemented()
        }
    }

    /**
     * 优先读取 BatteryManager 的容量属性；少数设备不支持时回退到系统电量广播。
     *
     * 返回空值代表系统未提供可靠读数，而不是把未知状态伪造成 0%。
     */
    private fun readBatteryPercent(): Int? {
        val batteryManager = applicationContext.getSystemService(Context.BATTERY_SERVICE)
            as? BatteryManager
        val managerValue = batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (managerValue != null && managerValue in 0..100) {
            return managerValue
        }
        val batteryIntent = applicationContext.registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        ) ?: return null
        val level = batteryIntent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = batteryIntent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) {
            return null
        }
        return (level * 100 / scale).coerceIn(0, 100)
    }

    /** 解除方法通道回调，避免 Activity 销毁后继续引用 Flutter 引擎。 */
    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val CHANNEL_NAME = "com.focubili.app/device_status"
        const val METHOD_GET_BATTERY_PERCENT = "getBatteryPercent"
    }
}
