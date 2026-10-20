package com.focubili.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Test

class SubtitleDocumentIdentityTest {
    @Test
    fun renewedSignatureRetainsDocumentIdentity() {
        assertEquals(
            SubtitleDocumentIdentity.key("https://aisubtitle.hdslb.com/bfs/subtitle/a.json?auth_key=old", "zh"),
            SubtitleDocumentIdentity.key("https://aisubtitle.hdslb.com/bfs/subtitle/a.json?auth_key=new", "zh"),
        )
    }

    @Test
    fun sameTrackCannotSilentlyChangeDocumentOrLanguage() {
        val original = SubtitleDocumentIdentity.key("https://aisubtitle.hdslb.com/bfs/subtitle/a.json", "zh")
        assertNotEquals(original, SubtitleDocumentIdentity.key("https://aisubtitle.hdslb.com/bfs/subtitle/b.json", "zh"))
        assertNotEquals(original, SubtitleDocumentIdentity.key("https://aisubtitle.hdslb.com/bfs/subtitle/a.json", "en"))
        assertEquals(64, original.length)
        assertFalse(original.contains("https"))
        assertFalse(original.contains("auth_key"))
    }
}
