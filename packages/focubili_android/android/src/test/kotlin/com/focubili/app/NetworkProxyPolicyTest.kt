package com.focubili.app

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class NetworkProxyPolicyTest {
    private val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("proxy.test", 8080))
    private val external = URI("https://api.bilibili.com/x/web-interface/nav")
    private val bypass = URI("http://localhost/status")
    private val system = object : ProxySelector() {
        override fun select(uri: URI): List<Proxy> =
            if (uri.host == "localhost") listOf(Proxy.NO_PROXY) else listOf(proxy, Proxy.NO_PROXY)
        override fun connectFailed(uri: URI, address: SocketAddress, exception: IOException) {}
    }

    @Test fun defaultsToSystemAndKeepsUrlSpecificBypassWithoutDirectFallback() {
        val policy = NetworkProxyPolicy(system)
        assertEquals(listOf(proxy), policy.select(external))
        assertEquals(listOf(Proxy.NO_PROXY), policy.select(bypass))
        assertEquals("PROXY proxy.test:8080", policy.resolveSystem(external))
        assertEquals("DIRECT", policy.resolveSystem(bypass))
    }

    @Test fun directAndManualModesDoNotChangeSystemResolution() {
        val policy = NetworkProxyPolicy(system)
        policy.configure("direct", null, null)
        assertEquals(listOf(Proxy.NO_PROXY), policy.select(external))
        assertEquals("PROXY proxy.test:8080", policy.resolveSystem(external))
        policy.configure("manual", "127.0.0.1", 7890)
        val manual = policy.select(external).single()
        assertEquals(Proxy.Type.HTTP, manual.type())
        assertEquals("127.0.0.1", (manual.address() as InetSocketAddress).hostString)
        assertEquals(7890, (manual.address() as InetSocketAddress).port)
        assertEquals("PROXY proxy.test:8080", policy.resolveSystem(external))
        policy.configure("system", null, null)
        assertEquals(listOf(proxy), policy.select(external))
    }

    @Test fun ipv6UsesBracketsWithoutDnsResolution() {
        val ipv6 = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("::1", 8080))
        val selector = object : ProxySelector() {
            override fun select(uri: URI) = listOf(ipv6)
            override fun connectFailed(uri: URI, address: SocketAddress, exception: IOException) {}
        }
        val policy = NetworkProxyPolicy(selector)
        assertEquals("PROXY [::1]:8080", policy.resolveSystem(external))
        policy.configure("manual", "[::1]", 7890)
        assertEquals("::1", (policy.select(external).single().address() as InetSocketAddress).hostString)
    }

    @Test fun rejectsCredentialsSchemesInvalidPortsAndUnknownModesAtomically() {
        val policy = NetworkProxyPolicy(system)
        for (host in listOf("", "http://proxy.test", "user:password@proxy.test", "proxy.test; DIRECT", "proxy test")) {
            assertThrows(Exception::class.java) { policy.configure("manual", host, 8080) }
        }
        for (port in listOf(0, -1, 65536)) {
            assertThrows(Exception::class.java) { policy.configure("manual", "proxy.test", port) }
        }
        assertThrows(Exception::class.java) { policy.configure("unknown", null, null) }
        assertEquals(listOf(proxy), policy.select(external))
    }

    @Test fun unsupportedSystemProxyIsAnErrorRatherThanDirect() {
        val selector = object : ProxySelector() {
            override fun select(uri: URI) = listOf(
                Proxy(Proxy.Type.SOCKS, InetSocketAddress.createUnresolved("proxy.test", 1080)),
                Proxy.NO_PROXY,
            )
            override fun connectFailed(uri: URI, address: SocketAddress, exception: IOException) {}
        }
        assertThrows(UnsupportedOperationException::class.java) {
            NetworkProxyPolicy(selector).resolveSystem(external)
        }
        assertEquals("DIRECT", NetworkProxyPolicy(null).resolveSystem(external))
    }

    @Test fun systemNetworkChangesDoNotOverwriteAppManualModeOrRecurse() {
        val policy = NetworkProxyPolicy(system)
        policy.configure("manual", "127.0.0.1", 7890)
        policy.updateSystemSelector(null)
        assertEquals("DIRECT", policy.resolveSystem(external))
        assertEquals(7890, (policy.select(external).single().address() as InetSocketAddress).port)
        policy.updateSystemSelector(system)
        policy.updateSystemSelector(policy)
        assertEquals("PROXY proxy.test:8080", policy.resolveSystem(external))
    }

    @Test fun backgroundEngineCannotChangeActivatedForegroundPolicy() {
        val policy = NetworkProxyPolicy(system)
        val activation = NetworkProxyActivation(policy)
        val active = activation.configure("manual", "127.0.0.1", 7890)
        assertEquals(active, activation.configure("direct", null, null))
        assertEquals("manual", active["mode"])
        assertEquals("127.0.0.1", active["host"])
        assertEquals(7890, active["port"])
        assertEquals(7890, (policy.select(external).single().address() as InetSocketAddress).port)
    }

    @Test fun invalidFirstConfigurationDoesNotPreventAValidStartup() {
        val policy = NetworkProxyPolicy(system)
        val activation = NetworkProxyActivation(policy)
        assertThrows(Exception::class.java) { activation.configure("manual", "", 7890) }
        assertEquals("direct", activation.configure("direct", null, null)["mode"])
        assertEquals(listOf(Proxy.NO_PROXY), policy.select(external))
    }

    @Test fun unreadableStartupPreferencesBlockNativeUntilValidConfiguration() {
        val policy = NetworkProxyPolicy(system)
        val activation = NetworkProxyActivation(policy)
        assertNull(activation.blockIfUnconfigured())
        assertThrows(IllegalStateException::class.java) { policy.select(external) }
        assertEquals("direct", activation.configure("direct", null, null)["mode"])
        assertEquals(listOf(Proxy.NO_PROXY), policy.select(external))
    }

    @Test fun failedBackgroundPreferencesCannotBlockAnAlreadyActivePolicy() {
        val policy = NetworkProxyPolicy(system)
        val activation = NetworkProxyActivation(policy)
        val active = activation.configure("system", null, null)
        assertEquals(active, activation.blockIfUnconfigured())
        assertEquals(listOf(proxy), policy.select(external))
    }

    @Test fun urlConnectionUsesManualProxyAndDirectModeWithoutExternalNetwork() {
        val previous = ProxySelector.getDefault()
        val policy = NetworkProxyPolicy(null)
        val worker = Executors.newSingleThreadExecutor()
        fun request(url: URL): String {
            val connection = url.openConnection() as HttpURLConnection
            connection.connectTimeout = 2000
            connection.readTimeout = 2000
            return try { connection.inputStream.bufferedReader().use { it.readText() } }
            finally { connection.disconnect() }
        }
        try {
            ProxySelector.setDefault(policy)
            ServerSocket(0).use { origin ->
                ServerSocket(0).use { server ->
                    server.soTimeout = 2000
                    origin.soTimeout = 2000
                    val url = URI("http://127.0.0.1:${origin.localPort}/api").toURL()
                    fun receive(socket: ServerSocket) = worker.submit<String> {
                        socket.accept().use { client ->
                            client.soTimeout = 2000
                            val line = client.getInputStream().bufferedReader().readLine()
                            client.getOutputStream().write(
                                "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nOK".toByteArray(),
                            )
                            line
                        }
                    }
                    policy.configure("manual", "127.0.0.1", server.localPort)
                    val proxied = receive(server)
                    assertEquals("OK", request(url))
                    assertTrue(proxied.get(3, TimeUnit.SECONDS).startsWith("GET $url "))
                    policy.configure("direct", null, null)
                    val direct = receive(origin)
                    assertEquals("OK", request(url))
                    assertTrue(direct.get(3, TimeUnit.SECONDS).startsWith("GET /api "))
                }
            }
        } finally {
            ProxySelector.setDefault(previous)
            worker.shutdownNow()
        }
    }

    @Test fun failedSystemHttpProxyDoesNotRetryDirectConnection() {
        val previous = ProxySelector.getDefault()
        try {
            ServerSocket(0).use { origin ->
                val closedPort = ServerSocket(0).use { it.localPort }
                val selected = Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("127.0.0.1", closedPort))
                val selector = object : ProxySelector() {
                    override fun select(uri: URI) = listOf(selected, Proxy.NO_PROXY)
                    override fun connectFailed(uri: URI, address: SocketAddress, exception: IOException) {}
                }
                ProxySelector.setDefault(NetworkProxyPolicy(selector))
                origin.soTimeout = 250
                val connection = URI("http://127.0.0.1:${origin.localPort}/api").toURL().openConnection() as HttpURLConnection
                connection.connectTimeout = 1000
                connection.readTimeout = 1000
                try { assertThrows(IOException::class.java) { connection.inputStream.close() } }
                finally { connection.disconnect() }
                assertThrows(SocketTimeoutException::class.java) { origin.accept().close() }
            }
        } finally {
            ProxySelector.setDefault(previous)
        }
    }
}
