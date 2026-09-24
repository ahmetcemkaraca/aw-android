package net.activitywatch.android

import net.activitywatch.android.fragments.isTrustedDashboardUrl
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WebUIOriginTest {
    @Test
    fun embeddedDashboardRequiresExactLoopbackOrigin() {
        assertTrue(isTrustedDashboardUrl("http://127.0.0.1:5600/"))
        assertTrue(isTrustedDashboardUrl("http://127.0.0.1:5600/#/activity/"))
        assertFalse(isTrustedDashboardUrl("http://localhost:5600/"))
        assertFalse(isTrustedDashboardUrl("http://127.0.0.1:5601/"))
        assertFalse(isTrustedDashboardUrl("https://127.0.0.1:5600/"))
        assertFalse(isTrustedDashboardUrl("http://user@127.0.0.1:5600/"))
        assertFalse(isTrustedDashboardUrl("http://127.0.0.1:5600/?token=secret"))
        assertFalse(isTrustedDashboardUrl("https://example.test/"))
    }
}
