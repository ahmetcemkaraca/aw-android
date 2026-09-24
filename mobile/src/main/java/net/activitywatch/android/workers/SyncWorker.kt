package net.activitywatch.android.workers

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.activitywatch.android.RustInterface

internal fun syncServerCanStart(vaultAvailable: Boolean, syncEnabled: Boolean): Boolean =
    vaultAvailable && syncEnabled

internal fun syncShouldRetry(success: Boolean, retryable: Boolean): Boolean =
    !success && retryable

/** Syncs through the local SQLCipher server and never reads or copies vault files. */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val rust = RustInterface(applicationContext)
        val vaultAvailable = !rust.needsVaultRecovery
        if (!vaultAvailable) return@withContext Result.success()
        if (!syncServerCanStart(vaultAvailable, rust.isNetworkSyncEnabled())) return@withContext Result.success()

        rust.startServerTask()
        val result = rust.runNetworkSync()
        val success = result.optBoolean("success", false)
        val retryable = result.optBoolean("retryable", false)
        when {
            success -> Result.success()
            syncShouldRetry(success, retryable) -> Result.retry()
            else -> Result.success()
        }
    }
}
