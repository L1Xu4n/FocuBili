package com.focubili.app;

import androidx.media3.common.C;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.source.LoadEventInfo;
import androidx.media3.exoplayer.source.MediaLoadData;
import androidx.media3.exoplayer.source.MediaSourceEventListener;
import java.net.SocketTimeoutException;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import org.junit.Test;
import static org.junit.Assert.*;

public class MediaRuntimeAnalyticsTest {
    @Test public void realMedia3LoadCallbacksKeepAudioVideoSeparateAndIgnoreOldSource() {
        MediaRuntimeDiagnostics log = new MediaRuntimeDiagnostics(() -> 100L);
        log.begin(false);
        MediaRuntimeDiagnostics.Attempt token = log.prepare();
        MediaRuntimeAnalytics analytics = new MediaRuntimeAnalytics(log);
        MediaSourceEventListener audio = analytics.sourceListener(token, "audio");
        MediaSourceEventListener video = analytics.sourceListener(token, "video");
        // URLs/DataSpec are deliberately null: the adapter must never read them.
        LoadEventInfo info = new LoadEventInfo(7L, null, null, Collections.emptyMap(), 0L, 1200L, 1024L);
        MediaLoadData data = new MediaLoadData(C.DATA_TYPE_MEDIA);
        audio.onLoadError(0, null, info, data, new SocketTimeoutException("Cookie=private"), false);
        video.onLoadCompleted(0, null, info, data);
        List<Map<String, Object>> records = log.snapshot();
        Map<String, Object> error = records.stream().filter(x -> "load_error".equals(x.get("event"))).findFirst().get();
        assertEquals("audio", error.get("track"));
        assertEquals("timeout", error.get("cause"));
        assertEquals(1200L, error.get("duration_ms"));
        assertEquals("video", records.stream().filter(x -> "load_end".equals(x.get("event"))).findFirst().get().get("track"));
        assertFalse(records.toString().contains("private"));
        log.prepare();
        int count = log.snapshot().size();
        audio.onLoadError(0, null, info, data, new SocketTimeoutException(), false);
        assertEquals(count, log.snapshot().size());
    }

    @Test public void httpErrorsOnlyExposeStatusAndCategory() {
        HttpDataSource.InvalidResponseCodeException error = new HttpDataSource.InvalidResponseCodeException(
            403, "secret signed URL", null,
            Collections.singletonMap("Cookie", Collections.singletonList("private")), null,
            "subtitle body".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        Map<String, Object> fields = MediaRuntimeAnalytics.Companion.failureFields(error);
        assertEquals(2, fields.size());
        assertEquals("http", fields.get("cause"));
        assertEquals(403, fields.get("http_status"));
        assertFalse(fields.toString().contains("secret"));
    }
}
