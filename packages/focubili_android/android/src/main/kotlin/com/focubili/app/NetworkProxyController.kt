package com.focubili.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Proxy
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.ProxySelector
import java.net.URI
import java.util.concurrent.Executors

/** Available in both the foreground engine and background subscription engines. */
internal class NetworkProxyController(context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.focubili/network_proxy")
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    @Volatile private var disposed = false

    init {
        observeSystemProxy(context.applicationContext)
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "blockIfUnconfigured" -> {
                // Corrupt/unreadable startup preferences must not leave native
                // playback using the default route while Dart refuses requests.
                val active = activation.blockIfUnconfigured()
                installPolicy()
                result.success(active)
            }
            "configure" -> {
                try {
                    val port = call.argument<Number>("port")?.toLong()
                    require(port == null || port in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong())
                    val active = activation.configure(
                        call.argument<String>("mode") ?: "system",
                        call.argument<String>("host"),
                        port?.toInt(),
                    )
                    installPolicy()
                    result.success(active)
                } catch (_: Exception) {
                    result.error("invalid_proxy", "Invalid HTTP proxy configuration", null)
                }
            }
            "resolve" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("invalid_url", "An HTTP(S) URL is required", null)
                    return
                }
                // Android's OS selector may evaluate a PAC URL. Never block the UI thread.
                executor.execute {
                    try {
                        installPolicy()
                        val value = policy.resolveSystem(URI(url))
                        main.post { if (!disposed) result.success(value) }
                    } catch (_: UnsupportedOperationException) {
                        main.post {
                            if (!disposed) result.error("unsupported_system_proxy", "Only HTTP system proxies are supported", null)
                        }
                    } catch (_: Exception) {
                        main.post {
                            if (!disposed) result.error("proxy_resolution_failed", "Could not resolve the system proxy", null)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
        // Other Flutter engines and the playback service share this process-wide policy.
    }

    companion object {
        // Capture Android's selector before installing our wrapper. System mode continues
        // to consult it for each URL, including OS bypass/PAC rules and network changes.
        private val policy = NetworkProxyPolicy(ProxySelector.getDefault())
        private val activation = NetworkProxyActivation(policy)
        private var receiver: BroadcastReceiver? = null

        @Synchronized private fun observeSystemProxy(context: Context) {
            if (receiver == null) {
                val listener = object : BroadcastReceiver() {
                    override fun onReceive(context: Context?, intent: Intent?) {
                        installPolicy()
                    }
                }
                val filter = IntentFilter(Proxy.PROXY_CHANGE_ACTION)
                if (Build.VERSION.SDK_INT >= 33) {
                    context.registerReceiver(listener, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    @Suppress("DEPRECATION")
                    context.registerReceiver(listener, filter)
                }
                // Application-context receiver lives with the process, including playback
                // services that outlive an individual foreground/background Flutter engine.
                receiver = listener
            }
            installPolicy()
        }

        @Synchronized private fun installPolicy() {
            val current = ProxySelector.getDefault()
            if (current !== policy) {
                // Android may replace its selector when the active Wi-Fi/PAC proxy changes.
                policy.updateSystemSelector(current)
                ProxySelector.setDefault(policy)
            }
        }
    }
}
