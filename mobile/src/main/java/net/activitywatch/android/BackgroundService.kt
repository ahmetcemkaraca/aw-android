package net.activitywatch.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.AlarmManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONException
import org.json.JSONObject
import net.activitywatch.android.watcher.UsageStatsWatcher

private const val TAG = "BackgroundService"
private const val CHANNEL_ID = "aw_background_channel"
private const val NOTIFICATION_ID = 1

class BackgroundService : Service() {

    companion object {
        const val ACTION_CAPTURE_STATE_CHANGED = "net.activitywatch.android.CAPTURE_STATE_CHANGED"
    }

    private lateinit var rustInterface: RustInterface

    // Becomes true after the server and local report workers are initialized.
    private var isFullyStarted = false

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "BackgroundService created")
        // Promote to foreground BEFORE slow native init so the OS 5-second
        // startForegroundService() countdown can't expire.  RustInterface loads
        // libaw_server.so + calls initialize() which can take several seconds on
        // slow/no-KVM emulators (CI).
        createNotificationChannel()
        val notification = createNotification()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            else
                0
        )
        cancelLegacySyncAlarm()
        rustInterface = RustInterface(this)
        if (rustInterface.needsVaultRecovery) {
            stopSelf()
            return
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (rustInterface.needsVaultRecovery) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_CAPTURE_STATE_CHANGED && isFullyStarted) {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, createNotification())
            return START_STICKY
        }
        Log.i(TAG, "BackgroundService started")

        if (!clearLegacyDashboardApiKey(this)) {
            Log.w(TAG, "Could not remove the legacy dashboard API key from config")
        }

        // Start the server
        rustInterface.startServerTask()

        // Run hostname migration off the main thread — migrateHostname() is a blocking JNI call.
        // Only mark as migrated on success so a retry is possible if the server wasn't ready yet.
        val prefs = AWPreferences(this)
        if (!prefs.hasMigratedHostname()) {
            CoroutineScope(Dispatchers.IO).launch {
                val hostname = rustInterface.getDeviceName(this@BackgroundService)
                val result = rustInterface.migrateHostname(hostname)
                Log.i(TAG, "Hostname migration result: $result")
                // The native migrateHostname() returns a plain-text success string
                // ("Migrated hostname for N bucket(s)") or a JSON error object
                // ({"error": "..."}).  Treat the plain-text prefix as success; only
                // retry when the native lib explicitly reports an error.
                val migrationSucceeded = if (result.startsWith("Migrated hostname for")) {
                    true
                } else {
                    val errorMsg = try {
                        JSONObject(result).optString("error", result)
                    } catch (e: JSONException) {
                        result.ifEmpty { "empty response" }
                    }
                    Log.w(TAG, "Hostname migration failed ($errorMsg); will retry on next start")
                    false
                }
                if (migrationSucceeded) {
                    prefs.setHostnameMigrated()
                }
            }
        }

        // Schedule event parsing
        scheduleEventParsing()

        // Schedule activity-time notifications (aw-notify)
        scheduleNotifyChecks()

        // Keep one periodic encrypted-manifest sync worker; consent and vault state are rechecked per run.
        scheduleSyncWorker()

        isFullyStarted = true
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, createNotification())
        return START_STICKY
    }

    private fun scheduleNotifyChecks() {
        val notifyRequest = androidx.work.PeriodicWorkRequest.Builder(
            net.activitywatch.android.workers.NotifyWorker::class.java,
            15, java.util.concurrent.TimeUnit.MINUTES
        )
            .addTag("NotifyWorker")
            .build()

        androidx.work.WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "NotifyWorker",
            androidx.work.ExistingPeriodicWorkPolicy.KEEP,
            notifyRequest
        )
        Log.i(TAG, "Scheduled activity-time notification worker (every 15 minutes)")
    }

    private fun scheduleSyncWorker() {
        val constraints = androidx.work.Constraints.Builder()
            .setRequiredNetworkType(androidx.work.NetworkType.CONNECTED)
            .build()
        val syncRequest = androidx.work.PeriodicWorkRequest.Builder(
            net.activitywatch.android.workers.SyncWorker::class.java,
            15, java.util.concurrent.TimeUnit.MINUTES
        )
            .setConstraints(constraints)
            .addTag("SyncWorker")
            .build()
        androidx.work.WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "SyncWorker",
            androidx.work.ExistingPeriodicWorkPolicy.KEEP,
            syncRequest
        )
    }

    private fun scheduleEventParsing() {
        val currentDate = java.util.Calendar.getInstance()
        val dueDate = java.util.Calendar.getInstance()
        // Set to midnight
        dueDate.set(java.util.Calendar.HOUR_OF_DAY, 0)
        dueDate.set(java.util.Calendar.MINUTE, 0)
        dueDate.set(java.util.Calendar.SECOND, 0)
        dueDate.set(java.util.Calendar.MILLISECOND, 0)
        if (dueDate.before(currentDate)) {
            dueDate.add(java.util.Calendar.HOUR_OF_DAY, 24)
        }
        val timeDiff = dueDate.timeInMillis - currentDate.timeInMillis

        val saveRequest = androidx.work.PeriodicWorkRequest.Builder(
            net.activitywatch.android.workers.EventParsingWorker::class.java,
            24, java.util.concurrent.TimeUnit.HOURS
        )
            .setInitialDelay(timeDiff, java.util.concurrent.TimeUnit.MILLISECONDS)
            .addTag("EventParsing")
            .build()

        androidx.work.WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "EventParsingWorker",
            androidx.work.ExistingPeriodicWorkPolicy.KEEP,
            saveRequest
        )
        Log.i(TAG, "Scheduled event parsing worker with initial delay: ${timeDiff}ms")
    }

    override fun onDestroy() {
        Log.i(TAG, "BackgroundService destroyed")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "PeakActivity local reports"
            val descriptionText = "Keeps the local reports service available and shows recording status"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(CHANNEL_ID, name, importance).apply {
                description = descriptionText
            }
            val notificationManager: NotificationManager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun cancelLegacySyncAlarm() {
        val intent = Intent("net.activitywatch.android.SYNC_ALARM").setPackage(packageName)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            0,
            intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
        ) ?: return
        (getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pendingIntent)
        pendingIntent.cancel()
    }

    private fun createNotification(): Notification {
        val pendingIntent: PendingIntent =
            Intent(this, MainActivity::class.java).let { notificationIntent ->
                PendingIntent.getActivity(
                    this, 0, notificationIntent,
                    PendingIntent.FLAG_IMMUTABLE
                )
            }

        val content = if (!isFullyStarted) getString(R.string.service_starting) else {
            val state = captureState(
                AWPreferences(this).isCaptureEnabled(),
                UsageStatsWatcher.isUsageAllowed(this),
            )
            when (state) {
                CaptureState.RECORDING -> getString(R.string.recording_running)
                CaptureState.PAUSED -> getString(R.string.recording_paused)
                CaptureState.PERMISSION_REQUIRED -> getString(R.string.recording_permission_required)
            }
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(content)
            .setSmallIcon(R.mipmap.aw_launcher_round) // Make sure this icon exists or use a fallback
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
