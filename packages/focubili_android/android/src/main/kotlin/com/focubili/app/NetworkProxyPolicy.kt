package com.focubili.app

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI

/** An application-process policy, never a change to the device's proxy settings. */
internal class NetworkProxyPolicy(@Volatile private var systemSelector: ProxySelector?) : ProxySelector() {
    private data class Configuration(val mode: String, val proxy: Proxy = Proxy.NO_PROXY)

    @Volatile private var configuration = Configuration("system")

    fun updateSystemSelector(selector: ProxySelector?) {
        if (selector !== this) systemSelector = selector
    }

    fun block() {
        configuration = Configuration("blocked")
    }

    fun configure(mode: String, host: String?, port: Int?) {
        require(mode in setOf("system", "direct", "manual")) { "Invalid proxy mode" }
        val proxy = if (mode == "manual") {
            require(port != null && port in 1..65535) { "Invalid proxy port" }
            val value = host?.trim()?.removeSurrounding("[", "]") ?: ""
            require(value.isNotEmpty() && value.none { it.isWhitespace() || it in "/\\@?#;" }) {
                "Invalid proxy host"
            }
            // Validate IPv6 and DNS syntax without performing a DNS lookup.
            require(URI("http", null, value, port, null, null, null).host != null) {
                "Invalid proxy host"
            }
            Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(value, port))
        } else Proxy.NO_PROXY
        configuration = Configuration(mode, proxy)
    }

    override fun select(uri: URI): List<Proxy> {
        val current = configuration
        return when (current.mode) {
            "blocked" -> throw IllegalStateException("Proxy settings are unavailable")
            "direct" -> listOf(Proxy.NO_PROXY)
            "manual" -> if (uri.scheme.equals("http", true) || uri.scheme.equals("https", true)) {
                listOf(current.proxy)
            } else listOf(Proxy.NO_PROXY)
            else -> selectSystem(uri)
        }
    }

    private fun selectSystem(uri: URI): List<Proxy> {
        // Do not let URLConnection retry DIRECT after an HTTP proxy fails. Dart
        // and media-kit also use only the OS's first selected route for this URL.
        val proxy = systemSelector?.select(uri)?.firstOrNull() ?: Proxy.NO_PROXY
        if (proxy.type() != Proxy.Type.DIRECT && proxy.type() != Proxy.Type.HTTP) {
            throw UnsupportedOperationException("Only HTTP system proxies are supported")
        }
        return listOf(proxy)
    }

    /** Resolve the OS policy even when this process is configured for manual/direct mode. */
    fun resolveSystem(uri: URI): String {
        require(uri.scheme.equals("http", true) || uri.scheme.equals("https", true))
        require(!uri.host.isNullOrBlank())
        return selectSystem(uri).joinToString("; ") { proxy ->
            when (proxy.type()) {
                Proxy.Type.DIRECT -> "DIRECT"
                Proxy.Type.HTTP -> {
                    val address = proxy.address() as? InetSocketAddress
                        ?: throw UnsupportedOperationException("Unsupported system proxy")
                    val host = address.hostString.removeSurrounding("[", "]")
                    if (host.isBlank() || host.any { it.isWhitespace() || it in "/\\@?#;" } ||
                        address.port !in 1..65535) {
                        throw UnsupportedOperationException("Unsupported system proxy")
                    }
                    val authority = if (host.contains(':')) "[$host]" else host
                    "PROXY $authority:${address.port}"
                }
                else -> throw UnsupportedOperationException("Only HTTP system proxies are supported")
            }
        }
    }

    override fun connectFailed(uri: URI, address: SocketAddress, exception: IOException) {
        if (configuration.mode == "system") systemSelector?.connectFailed(uri, address, exception)
    }
}

/** Foreground/background Flutter engines must share one startup snapshot. */
internal class NetworkProxyActivation(private val policy: NetworkProxyPolicy) {
    private var active: Map<String, Any>? = null

    @Synchronized fun configure(mode: String, host: String?, port: Int?): Map<String, Any> {
        active?.let { return it }
        policy.configure(mode, host, port)
        return mapOf(
            "mode" to mode,
            "host" to (host?.trim()?.removeSurrounding("[", "]") ?: ""),
            "port" to (port ?: 7890),
        ).also { active = it }
    }

    @Synchronized fun blockIfUnconfigured(): Map<String, Any>? {
        active?.let { return it }
        policy.block()
        return null
    }
}
