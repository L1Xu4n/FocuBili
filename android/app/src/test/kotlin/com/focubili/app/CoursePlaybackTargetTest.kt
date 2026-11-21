package com.focubili.app

import org.junit.Assert.*
import org.junit.Test

class CoursePlaybackTargetTest {
    @Test fun keepsCourseAndUgcNamespacesSeparate() {
        assertNull(CoursePlaybackTarget.create("BV1GJ411x7h7", 1L, 2L))
        assertNull(CoursePlaybackTarget.create("cheese:ss0", 1L, 2L))
        assertNull(CoursePlaybackTarget.create("cheese:ss968174948", null, 2L))
        assertNull(CoursePlaybackTarget.create("cheese:ss968174948", 1L, -1L))
        assertNull(CoursePlaybackTarget.create("cheese:ss9223372036854775808", 1L, 2L))
    }
    @Test fun carries64BitIdentifiersWithoutUgcParameters() {
        val target = CoursePlaybackTarget.create("cheese:ss968174948", 1913937L, 114973875373160L)!!
        val parameters = target.parameters(31663719867L, 64, 16)
        assertEquals("114973875373160", parameters["avid"])
        assertEquals("31663719867", parameters["cid"])
        assertEquals("1913937", parameters["ep_id"])
        assertFalse(parameters.containsKey("bvid"))
        assertEquals("https://www.bilibili.com/cheese/play/ep1913937", target.referer)
        assertEquals("https://www.bilibili.com/cheese/play/ss968174948",
            CoursePlaybackTarget.seasonPage("cheese:ss968174948"))
    }
}
