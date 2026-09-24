package net.activitywatch.android.workers

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncWorkerPolicyTest {
    @Test
    fun lockedVaultOrDisabledConsentNeverStartsTheServer() {
        assertFalse(syncServerCanStart(vaultAvailable = false, syncEnabled = true))
        assertFalse(syncServerCanStart(vaultAvailable = true, syncEnabled = false))
        assertTrue(syncServerCanStart(vaultAvailable = true, syncEnabled = true))
    }

    @Test
    fun onlyTransientFailuresRequestAWorkManagerRetry() {
        assertFalse(syncShouldRetry(success = true, retryable = true))
        assertFalse(syncShouldRetry(success = false, retryable = false))
        assertTrue(syncShouldRetry(success = false, retryable = true))
    }
}
