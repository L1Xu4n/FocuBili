package com.focubili.app;

import java.net.HttpURLConnection;
import java.net.URI;

/** Applies only a validated optional header, never modifying session or routing. */
public final class OrdinaryPlaybackUserAgent {
    private OrdinaryPlaybackUserAgent() {}

    static String safeForChannel(String value) {
        if (value == null || value.isEmpty() || value.length() > 512) return null;
        for (int index = 0; index < value.length(); index++) {
            char c = value.charAt(index);
            if (c < 0x20 || c > 0x7e) return null;
        }
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }

    static String select(
            String value, boolean confirmedOrdinaryUpload, boolean guestOverride, int quality) {
        if (!confirmedOrdinaryUpload || guestOverride ||
                (quality != 16 && quality != 32 && quality != 64)) {
            return null;
        }
        return safeForChannel(value);
    }

    /** Called by the Android HTTPS playback API, not Media3 or the login WebView. */
    static void apply(HttpURLConnection connection, URI endpoint, String fallback, String selected) {
        boolean allowed = "https".equals(endpoint.getScheme()) &&
                "api.bilibili.com".equals(endpoint.getHost()) &&
                (endpoint.getPort() == -1 || endpoint.getPort() == 443) &&
                endpoint.getUserInfo() == null && endpoint.getFragment() == null &&
                ("/x/player/playurl".equals(endpoint.getRawPath()) ||
                 "/x/player/wbi/playurl".equals(endpoint.getRawPath()));
        String custom = allowed ? safeForChannel(selected) : null;
        connection.setRequestProperty("User-Agent", custom == null ? fallback : custom);
    }
}
