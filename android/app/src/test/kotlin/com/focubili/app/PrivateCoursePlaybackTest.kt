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

    @Test fun expiryCannotExceedLocalWindow() {
        val now = 1_000L
        assertFalse(PrivateCoursePlayback.acceptsWindow(now, now))
        assertFalse(PrivateCoursePlayback.acceptsWindow(now, now - 1))
        assertTrue(PrivateCoursePlayback.acceptsWindow(now, now + PrivateCoursePlayback.MAX_WINDOW))
        assertFalse(PrivateCoursePlayback.acceptsWindow(now, now + PrivateCoursePlayback.MAX_WINDOW + 1))
    }
}
