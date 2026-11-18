package com.focubili.app

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class PrivateCoursePlaybackTest {
    @Test fun exactAccountAndLessonAreRequired() {
        val root = File(System.getProperty("java.io.tmpdir")).canonicalFile.resolve("private_course_v1")
        val lesson = root.resolve("51/1-2-3-4")
        val own = lesson.resolve("video.bin").path
        assertTrue(PrivateCoursePlayback.matches(lesson, own, "video.bin"))
        assertFalse(PrivateCoursePlayback.matches(lesson, root.resolve("8/1-2-3-4/video.bin").path, "video.bin"))
        assertFalse(PrivateCoursePlayback.matches(lesson, own, "audio.bin"))
        assertTrue(PrivateCoursePlayback.restricted(root, own))
        assertFalse(PrivateCoursePlayback.restricted(root, root.path + "_other/video.bin"))
    }

    @Test fun serverDeadlinesAndVerifiedNoDeadlineUseDifferentShapes() {
        val checked = 1_000L
        val day = 24 * 60 * 60 * 1000L
        val now = checked + 3 * day
        val end = checked + 5 * day
        assertTrue(PrivateCoursePlayback.acceptsWindow(now, checked, "serverDeadline", end))
        assertFalse(PrivateCoursePlayback.acceptsWindow(end, checked, "serverDeadline", end))
        assertFalse(PrivateCoursePlayback.acceptsWindow(now, checked, "serverDeadline", null))
        assertFalse(PrivateCoursePlayback.acceptsWindow(now, checked, "legacyReceipt", end))
        assertTrue(PrivateCoursePlayback.acceptsWindow(now, checked, "explicitLongTerm", null))
        assertTrue(PrivateCoursePlayback.acceptsWindow(now, checked, "noDeclaredDeadline", null))
        assertFalse(PrivateCoursePlayback.acceptsWindow(now, checked, "noDeclaredDeadline", end))
        assertFalse(PrivateCoursePlayback.acceptsWindow(now, 0L, "noDeclaredDeadline", null))
        assertFalse(PrivateCoursePlayback.acceptsWindow(checked - 1, checked, "noDeclaredDeadline", null))
        assertFalse(PrivateCoursePlayback.acceptsWindow(now, checked, null, null))
    }
}
