package com.focubili.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 读取系统公开的网络连接类型、计量状态与 Data Saver 限制。
 *
 * 仅暴露非敏感的枚举字符串，不读取 SSID、运营商、IP 或任何设备标识。
 * 同时供前台和 WorkManager 后台无界面引擎复用。
 */
object AndroidNetworkStatusReader {
    const val NETWORK_WIFI = "wifi"
    const val NETWORK_MOBILE = "mobile"
    const val NETWORK_ETHERNET = "ethernet"
    const val NETWORK_OFFLINE = "offline"
    const val NETWORK_OTHER = "other"

    const val METERED_UNKNOWN = "unknown"
    const val METERED_UNMETERED = "unmetered"
    const val METERED_METERED = "metered"

    const val LOW_DATA_UNKNOWN = "unknown"
    const val LOW_DATA_OFF = "off"
    const val LOW_DATA_ON = "on"

    fun readNetworkType(context: Context): String {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE)
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

    fun readNetworkStatus(context: Context): Map<String, String> {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager
            ?: return mapOf(
                "type" to NETWORK_OTHER,
                "metered" to METERED_UNKNOWN,
                "lowDataMode" to LOW_DATA_UNKNOWN,
            )

        val lowDataMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            when (connectivityManager.restrictBackgroundStatus) {
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED -> LOW_DATA_ON
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED,
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_WHITELISTED -> LOW_DATA_OFF
                else -> LOW_DATA_UNKNOWN
            }
        } else {
            LOW_DATA_UNKNOWN
        }

        val activeNetwork = connectivityManager.activeNetwork
            ?: return mapOf(
                "type" to NETWORK_OFFLINE,
                "metered" to METERED_UNKNOWN,
                "lowDataMode" to lowDataMode,
            )
        val capabilities = connectivityManager.getNetworkCapabilities(activeNetwork)
            ?: return mapOf(
                "type" to NETWORK_OTHER,
                "metered" to METERED_UNKNOWN,
                "lowDataMode" to lowDataMode,
            )

        val type = when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NETWORK_WIFI
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NETWORK_MOBILE
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> NETWORK_ETHERNET
            else -> NETWORK_OTHER
        }

        val metered = when {
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ->
                METERED_UNMETERED
            connectivityManager.isActiveNetworkMetered -> METERED_METERED
            else -> METERED_UNKNOWN
        }

        return mapOf(
            "type" to type,
            "metered" to metered,
            "lowDataMode" to lowDataMode,
        )
    }
}

/**
 * 为前台与 WorkManager 后台引擎提供统一的网络计量状态查询通道。
 */
class AndroidNetworkStatusController(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val applicationContext = context.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_GET_NETWORK_STATUS -> result.success(
                AndroidNetworkStatusReader.readNetworkStatus(applicationContext),
            )
            METHOD_GET_NETWORK_TYPE -> result.success(
                AndroidNetworkStatusReader.readNetworkType(applicationContext),
            )
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL_NAME = "com.focubili.app/android_network_status"
        const val METHOD_GET_NETWORK_STATUS = "getNetworkStatus"
        const val METHOD_GET_NETWORK_TYPE = "getNetworkType"
    }
}
