package com.focubili.app;

import org.junit.Test;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.Proxy;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

public final class OrdinaryPlaybackUserAgentTest {
    private static final String LOCAL = "LocalFixtureClient/1.0";
    private static final String DEFAULT = "OriginalFixtureClient/2";
    private static final String COOKIE = "local_test=synthetic";
    private static final int TIMEOUT_MS = 3000;

    @Test
    public void nativeChannelRejectsUntrustedBytesAndUnknownMedia() {
        assertEquals(LOCAL, OrdinaryPlaybackUserAgent.select(" " + LOCAL, true, false, 64));
        assertEquals(LOCAL, OrdinaryPlaybackUserAgent.select(LOCAL, true, false, 16));
        assertEquals(LOCAL, OrdinaryPlaybackUserAgent.select(LOCAL, true, false, 32));
        assertNull(OrdinaryPlaybackUserAgent.select(LOCAL, true, false, 80));
        assertNull(OrdinaryPlaybackUserAgent.select(LOCAL, false, false, 64));
        assertNull(OrdinaryPlaybackUserAgent.select(LOCAL, true, true, 64));
        assertNull(OrdinaryPlaybackUserAgent.select(null, true, false, 64));
        assertNull(OrdinaryPlaybackUserAgent.select(" ", true, false, 64));
        assertNull(OrdinaryPlaybackUserAgent.select("Fixture\r\nX-Test:", true, false, 64));
        assertNull(OrdinaryPlaybackUserAgent.select("Fixture\t1", true, false, 64));
        assertNull(OrdinaryPlaybackUserAgent.select("x".repeat(513), true, false, 64));
    }

    @Test(timeout = 20000)
    public void productionHeaderAdapterSendsExactlyOneHeaderOnlyForAllowedRoute() throws Exception {
        List<String> paths = List.of(
                "https://api.bilibili.com/x/player/playurl",
                "https://api.bilibili.com/x/player/wbi/playurl",
                "https://api.bilibili.com/x/web-interface/nav",
                "https://api.bilibili.com/pugv/player/web/playurl",
                "https://api.bilibili.com.fake.invalid/x/player/playurl",
                "https://api.bilibili.com:7890/x/player/playurl",
                "https://a.bilivideo.com/x/player/playurl",
                "http://api.bilibili.com/x/player/playurl",
                "https://api.bilibili.com/x/player/playurl"
        );
        List<String> expectedUa =
                List.of(LOCAL, LOCAL, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT);
        ExecutorService fixture = Executors.newSingleThreadExecutor();
        try (ServerSocket server = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(TIMEOUT_MS);
            for (int i = 0; i < paths.size(); i++) {
                String target = "/case/" + i;
                Future<Map<String, List<String>>> observed =
                        fixture.submit(() -> readFirstRequest(server, target));
                URI endpoint = URI.create(paths.get(i));
                URI loopback = URI.create("http://127.0.0.1:" + server.getLocalPort() + target);
                HttpURLConnection connection =
                        (HttpURLConnection) loopback.toURL().openConnection(Proxy.NO_PROXY);
                try {
                    connection.setConnectTimeout(TIMEOUT_MS);
                    connection.setReadTimeout(TIMEOUT_MS);
                    connection.setInstanceFollowRedirects(false);
                    connection.setRequestProperty("Cookie", COOKIE);
                    OrdinaryPlaybackUserAgent.apply(
                            connection, endpoint, DEFAULT, i == paths.size() - 1 ? null : LOCAL
                    );
                    assertEquals(HttpURLConnection.HTTP_PRECON_FAILED, connection.getResponseCode());
                    Map<String, List<String>> headers = observed.get(TIMEOUT_MS, TimeUnit.MILLISECONDS);
                    assertEquals(List.of(expectedUa.get(i)), headers.get("user-agent"));
                    assertEquals(List.of(COOKIE), headers.get("cookie"));
                } finally {
                    connection.disconnect();
                }
            }
            // A repeated attempt would either have the wrong path in the next case or be queued here.
            server.setSoTimeout(200);
            assertThrows(SocketTimeoutException.class, () -> server.accept().close());
        } finally {
            fixture.shutdownNow();
            assertTrue(fixture.awaitTermination(TIMEOUT_MS, TimeUnit.MILLISECONDS));
        }
    }

    private static Map<String, List<String>> readFirstRequest(ServerSocket server, String target)
            throws IOException {
        try (Socket socket = server.accept()) {
            socket.setSoTimeout(TIMEOUT_MS);
            BufferedReader request = new BufferedReader(
                    new InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII));
            String requestLine = request.readLine();
            assertEquals("GET " + target + " HTTP/1.1", requestLine);
            Map<String, List<String>> headers = new HashMap<>();
            for (String line = request.readLine(); line != null; line = request.readLine()) {
                if (line.isEmpty()) {
                    // Give the client a complete final response, not a disconnect to retry.
                    socket.getOutputStream().write(("HTTP/1.1 412 Precondition Failed\r\n"
                            + "Content-Length: 0\r\nConnection: close\r\n\r\n")
                            .getBytes(StandardCharsets.US_ASCII));
                    return headers;
                }
                int colon = line.indexOf(':');
                if (colon <= 0) throw new IOException("Invalid fixture request header");
                String name = line.substring(0, colon).toLowerCase(Locale.ROOT);
                headers.computeIfAbsent(name, ignored -> new ArrayList<>())
                        .add(line.substring(colon + 1).trim());
            }
            throw new IOException("Fixture request ended before the headers");
        }
    }
}
