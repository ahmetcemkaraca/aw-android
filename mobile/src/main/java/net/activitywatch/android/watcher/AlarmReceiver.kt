package net.activitywatch.android.watcher

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

private const val TAG = "AlarmReceiver"

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.w(TAG, "AlarmReceiver called")
        val usw = UsageStatsWatcher(context)
        if (intent.action == "android.intent.action.BOOT_COMPLETED") {
            Log.i(TAG, "Received BOOT_COMPLETED; restoring local service state")
            if (net.activitywatch.android.AWPreferences(context).isCaptureEnabled()
                && UsageStatsWatcher.isUsageAllowed(context)) {
                usw.setupAlarm()
            }
            val serviceIntent = Intent(context, net.activitywatch.android.BackgroundService::class.java)
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } else if (intent.action == "net.activitywatch.android.watcher.LOG_DATA") {
            if (net.activitywatch.android.AWPreferences(context).isCaptureEnabled()
                && UsageStatsWatcher.isUsageAllowed(context)) {
                val pendingResult = goAsync()
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        usw.sendHeartbeatsSuspend()
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to send heartbeats from alarm", e)
                    } finally {
                        pendingResult.finish()
                    }
                }
            }
        } else {
            Log.w(TAG, "Unknown intent $intent with action ${intent.action}, doing nothing")
        }
    }
}
