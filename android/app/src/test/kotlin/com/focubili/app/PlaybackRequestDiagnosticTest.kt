package com.focubili.app

import org.junit.Assert.*
import org.junit.Test

class PlaybackRequestDiagnosticTest {
    @Test fun signingFailureIsDifferentFromUnsignedRequestAndNeverClaimsFallback() {
        val failed = PlaybackRequestDiagnostic(1, true, 80)
        failed.stage = "signing"
        val values = failed.toMap(false)
        assertEquals(true, values["wbi_enabled"])
        assertEquals(false, values["wbi_signed"])
        assertEquals(false, values["wbi_fallback"])
        assertEquals(false, values["playurl_attempted"])
        assertEquals("signing", values["stage"])
        assertEquals("error", values["outcome"])
    }

    @Test fun downgradeKeepsRequestedReturnedAndSelectedQualitySeparate() {
        val diagnostic = PlaybackRequestDiagnostic(2, true, 80)
        diagnostic.wbiSigned = true
        diagnostic.playurlAttempted = true
        diagnostic.returnedQuality = 80
        diagnostic.selectedQuality = 16
        diagnostic.authState = "session_present_unverified"
        val values = diagnostic.toMap(true)
        assertEquals(80, values["requested_quality"])
        assertEquals(80, values["returned_quality"])
        assertEquals(16, values["selected_quality"])
        assertEquals("quality_downgrade", values["outcome"])
        assertEquals("session_present_unverified", values["auth_state"])
        assertEquals(16, values.size)
    }

    @Test fun onlyAnExplicitNavResultConfirmsAuthentication() {
        val diagnostic = PlaybackRequestDiagnostic(3, false, 64)
        diagnostic.authState = "session_present_unverified"
        diagnostic.observeNavigation(0, null)
        assertEquals("session_present_unverified", diagnostic.authState)
        diagnostic.observeNavigation(0, true)
        assertEquals("authenticated", diagnostic.authState)
        diagnostic.observeNavigation(-101, null)
        assertEquals("expired", diagnostic.authState)
        diagnostic.authState = "anonymous"
        diagnostic.observeNavigation(0, true)
        assertEquals("anonymous", diagnostic.authState)
        diagnostic.observeNavigation(-101, false)
        assertEquals("anonymous", diagnostic.authState)
    }
}
