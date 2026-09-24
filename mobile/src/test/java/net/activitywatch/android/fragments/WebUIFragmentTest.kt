package net.activitywatch.android.fragments

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WebUIFragmentTest {
    @Test
    fun `accepts only the embedded loopback dashboard URL`() {
        assertTrue(isTrustedDashboardUrl("http://127.0.0.1:5600/#/settings/"))
        assertTrue(isTrustedDashboardUrl("http://127.0.0.1:5600/"))
    }

    @Test
    fun `rejects non-exact dashboard URLs and origins`() {
        for (url in listOf(
            "https://127.0.0.1:5600/",
            "http://localhost:5600/",
            "http://[::1]:5600/",
            "http://127.0.0.1:5601/",
            "http://user@127.0.0.1:5600/",
            "http://127.0.0.1:5600/settings",
            "http://127.0.0.1:5600/?token=secret",
            "not a url",
        )) assertFalse(isTrustedDashboardUrl(url))

        assertTrue(isTrustedDashboardOrigin("http://127.0.0.1:5600"))
        for (origin in listOf(
            "https://127.0.0.1:5600",
            "http://localhost:5600",
            "http://127.0.0.1:5601",
            "http://127.0.0.1:5600?token=secret",
            "http://127.0.0.1:5600/#/settings",
        )) assertFalse(isTrustedDashboardOrigin(origin))
    }
}
