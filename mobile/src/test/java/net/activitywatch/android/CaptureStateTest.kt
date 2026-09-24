package net.activitywatch.android

import org.junit.Assert.assertEquals
import org.junit.Test

class CaptureStateTest {
    @Test
    fun `permission denial overrides the stored recording choice`() {
        assertEquals(CaptureState.PERMISSION_REQUIRED, captureState(recordingEnabled = true, usageAccessGranted = false))
    }

    @Test
    fun `paused capture stays paused even when usage access is missing`() {
        assertEquals(CaptureState.PAUSED, captureState(recordingEnabled = false, usageAccessGranted = false))
    }

    @Test
    fun `capture is active only when user choice and usage access are both present`() {
        assertEquals(CaptureState.RECORDING, captureState(recordingEnabled = true, usageAccessGranted = true))
        assertEquals(CaptureState.PAUSED, captureState(recordingEnabled = false, usageAccessGranted = true))
    }
}
