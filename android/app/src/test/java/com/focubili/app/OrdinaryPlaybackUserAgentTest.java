package com.focubili.app;

import com.sun.net.httpserver.HttpServer;
import org.junit.Test;

import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

public final class OrdinaryPlaybackUserAgentTest {
    private static final String LOCAL = "LocalFixtureClient/1.0";
    private static final String DEFAULT = "OriginalFixtureClient/2";
    private static final String COOKIE = "local_test=synthetic";

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

    @Test
    public void productionHeaderAdapterSendsExactlyOneHeaderOnlyForAllowedRoute() throws Exception {
        List<String> observedUa = Collections.synchronizedList(new ArrayList<>());
        List<String> observedCookie = Collections.synchronizedList(new ArrayList<>());
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", exchange -> {
            String actual = exchange.getRequestHeaders().getFirst("User-Agent");
            observedUa.add(actual);
            observedCookie.add(exchange.getRequestHeaders().getFirst("Cookie"));
            exchange.sendResponseHeaders(412, -1);
            exchange.close();
        });
        server.start();
        try {
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
            for (int i = 0; i < paths.size(); i++) {
                URI endpoint = URI.create(paths.get(i));
                URI loopback = URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/");
                HttpURLConnection connection = (HttpURLConnection) loopback.toURL().openConnection();
                try {
                    connection.setInstanceFollowRedirects(false);
                    connection.setRequestProperty("Cookie", COOKIE);
                    OrdinaryPlaybackUserAgent.apply(
                            connection, endpoint, DEFAULT, i == paths.size() - 1 ? null : LOCAL
                    );
                    assertEquals(412, connection.getResponseCode());
                    assertEquals(i + 1, observedUa.size());
                } finally {
                    connection.disconnect();
                }
            }
            assertEquals(List.of(LOCAL, LOCAL, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT, DEFAULT), observedUa);
            assertEquals(Collections.nCopies(paths.size(), COOKIE), observedCookie);
        } finally {
            server.stop(0);
        }
    }
}
