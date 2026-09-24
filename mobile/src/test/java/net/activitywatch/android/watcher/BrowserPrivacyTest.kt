package net.activitywatch.android.watcher

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BrowserPrivacyTest {
    @Test
    fun explicitPrivateBrowsingIndicatorsAreRecognizedWithoutInspectingPageText() {
        assertTrue(isPrivateBrowsingIndicator("Open new Incognito tab"))
        assertTrue(isPrivateBrowsingIndicator("Private Browsing"))
        assertFalse(isPrivateBrowsingIndicator("A private company"))
        assertFalse(isPrivateBrowsingIndicator("example.com - Mozilla Firefox"))
        assertFalse(isPrivateBrowsingIndicator(null))
    }
}
