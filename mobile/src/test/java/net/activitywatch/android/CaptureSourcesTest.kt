package net.activitywatch.android

import org.junit.Assert.assertEquals
import org.junit.Test

class CaptureSourcesTest {
    @Test
    fun lockedOrPausedVaultDisablesEveryAutomaticSource() {
        assertEquals(
            CaptureSources(false, false, false),
            captureSources(
                vaultReady = false, recordingEnabled = true, usageAccessGranted = true,
                browserOptIn = true, accessibilityGranted = true,
                mediaOptIn = true, notificationAccessGranted = true,
            ),
        )
        assertEquals(
            CaptureSources(false, false, false),
            captureSources(
                vaultReady = true, recordingEnabled = false, usageAccessGranted = true,
                browserOptIn = true, accessibilityGranted = true,
                mediaOptIn = true, notificationAccessGranted = true,
            ),
        )
    }

    @Test
    fun optionalSourcesRemainIndependentFromUsageStatsPermission() {
        assertEquals(
            CaptureSources(false, true, true),
            captureSources(
                vaultReady = true, recordingEnabled = true, usageAccessGranted = false,
                browserOptIn = true, accessibilityGranted = true,
                mediaOptIn = true, notificationAccessGranted = true,
            ),
        )
    }

    @Test
    fun revokingOptionalPermissionStopsOnlyThatSource() {
        assertEquals(
            CaptureSources(true, false, true),
            captureSources(
                vaultReady = true, recordingEnabled = true, usageAccessGranted = true,
                browserOptIn = true, accessibilityGranted = false,
                mediaOptIn = true, notificationAccessGranted = true,
            ),
        )
        assertEquals(
            CaptureSources(true, true, false),
            captureSources(
                vaultReady = true, recordingEnabled = true, usageAccessGranted = true,
                browserOptIn = true, accessibilityGranted = true,
                mediaOptIn = true, notificationAccessGranted = false,
            ),
        )
    }
}
