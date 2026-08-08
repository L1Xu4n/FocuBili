package com.focubili.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 向 Flutter 提供系统公开的当前电量与网络连接类型。
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
            METHOD_GET_NETWORK_TYPE -> result.success(readNetworkType())
            METHOD_GET_DIAGNOSTIC_DEVICE_INFO -> result.success(readDiagnosticDeviceInfo())
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

    /**
     * 只读取当前活动网络的传输类型，不读取 Wi-Fi 名称、运营商、IP 或任何设备标识。
     *
     * Android 没有活动网络时返回 offline；无法识别的 VPN 等连接统一返回 other。
     */
    private fun readNetworkType(): String {
        val connectivityManager = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager ?: return NETWORK_OTHER
        val activeNetwork = connectivityManager.activeNetwork ?: return NETWORK_OFFLINE
        val capabilities = connectivityManager.getNetworkCapabilities(activeNetwork)
            ?: return NETWORK_OTHER
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NETWORK_WIFI
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NETWORK_MOBILE
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> NETWORK_ETHERNET
            else -> NETWORK_OTHER
        }
    }

    /**
     * 返回问题诊断页需要的公开系统版本、API 级别和设备型号。
     *
     * 不读取序列号、Android ID、MAC 地址、广告标识符或任何账号资料，确保复制诊断文本可安全反馈。
     */
    private fun readDiagnosticDeviceInfo(): Map<String, Any> {
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        val modelName = Build.MODEL?.trim().orEmpty()
        val displayModel = when {
            modelName.isBlank() -> "未知设备"
            manufacturer.isBlank() || modelName.contains(manufacturer, ignoreCase = true) -> modelName
            else -> "$manufacturer $modelName"
        }
        return mapOf(
            "androidRelease" to Build.VERSION.RELEASE?.trim().orEmpty().ifBlank { "未知" },
            "apiLevel" to Build.VERSION.SDK_INT,
            "model" to displayModel,
        )
    }

    /** 解除方法通道回调，避免 Activity 销毁后继续引用 Flutter 引擎。 */
    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val CHANNEL_NAME = "com.focubili.app/device_status"
        const val METHOD_GET_BATTERY_PERCENT = "getBatteryPercent"
        const val METHOD_GET_NETWORK_TYPE = "getNetworkType"
        const val METHOD_GET_DIAGNOSTIC_DEVICE_INFO = "getDiagnosticDeviceInfo"
        const val NETWORK_WIFI = "wifi"
        const val NETWORK_MOBILE = "mobile"
        const val NETWORK_ETHERNET = "ethernet"
        const val NETWORK_OFFLINE = "offline"
        const val NETWORK_OTHER = "other"
    }
}
