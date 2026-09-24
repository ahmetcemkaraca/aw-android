package net.activitywatch.android.watcher

import android.content.Context
import android.util.Log
import net.activitywatch.android.RustInterface
import net.activitywatch.android.AWPreferences
import net.activitywatch.android.data.AppSession
import net.activitywatch.android.parser.SessionParser
import net.activitywatch.android.utils.SessionUtils
import org.json.JSONObject
import org.threeten.bp.DateTimeUtils
import org.threeten.bp.Instant
import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Locale
import kotlinx.coroutines.*
import net.activitywatch.android.captureSources

const val SESSION_BUCKET_ID = "aw-watcher-android"
const val UNLOCK_BUCKET_ID = "aw-watcher-android-unlock"

class SessionEventWatcher(val context: Context) {
    private val ri = RustInterface(context)
    private val sessionParser = SessionParser(context)
    private val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)

    var lastUpdated: Instant? = null

    companion object {
        const val TAG = "SessionEventWatcher"
        private val lock = java.util.concurrent.locks.ReentrantLock()
    }

    // queryEvents uses an inclusive lower bound, so replaying the last stored
    // session's start timestamp would duplicate that session on every run.
    private fun nextQueryStartTimestamp(): Long = (lastUpdated?.toEpochMilli()?.plus(1L)) ?: 0L

    suspend fun sendSessionEventsSuspend() {
        Log.w(TAG, "Starting SendSessionEventTask (awaitable)")
        withContext(Dispatchers.IO) {
            val result = processEventsSinceLastUpdate()
            Log.w(TAG, "Finished SendSessionEventTask, sent $result session events")
        }
    }

    private fun getLastEventTime(): Instant? {
        val events = ri.getEventsJSON(SESSION_BUCKET_ID, limit = 1)
        return if (events.length() == 1) {
            val lastEvent = events[0] as JSONObject
            val timestampString = lastEvent.getString("timestamp")
            try {
                val timeCreatedDate = isoFormatter.parse(timestampString)
                DateTimeUtils.toInstant(timeCreatedDate)
            } catch (e: ParseException) {
                Log.e(TAG, "Unable to parse timestamp: $timestampString")
                null
            }
        } else if (events.length() == 0) {
            null  // normal on first run
        } else {
            Log.w(TAG, "Expected 1 event for last-event lookup, got ${events.length()}")
            null
        }
    }

    /**
     * Synchronously process events since last update.
     * Returns the number of events sent.
     */
    fun processEventsSinceLastUpdate(): Int {
        if (!lock.tryLock()) {
            Log.i(TAG, "processEventsSinceLastUpdate already running, skipping concurrent call")
            return 0
        }
        try {
            return processEventsSinceLastUpdateLocked()
        } finally {
            lock.unlock()
        }
    }

    private fun processEventsSinceLastUpdateLocked(): Int {
        if (!captureAllowed()) return 0
        Log.i(TAG, "Processing session events...")

        // Create bucket for session events
        ri.createBucketHelper(SESSION_BUCKET_ID, "currentwindow")
        ri.createBucketHelper(UNLOCK_BUCKET_ID, "os.lockscreen.unlocks")

        lastUpdated = getLastEventTime()
        Log.d(TAG, if (lastUpdated == null) "No prior session checkpoint" else "Loaded local session checkpoint")

        val startTimestamp = nextQueryStartTimestamp()
        val sessions = sessionParser.parseUsageEventsSince(startTimestamp)
        if (!captureAllowed()) return 0
        val unlockTimestamps = sessionParser.parseUnlockEventsSince(startTimestamp)

        var eventsSent = 0

        for (session in sessions) {
            if (!captureAllowed()) break
            // Insert session as individual event
            insertSessionAsEvent(session)
            eventsSent++
        }
        
        for (timestamp in unlockTimestamps) {
            if (!captureAllowed()) break
            val instant = DateTimeUtils.toInstant(java.util.Date(timestamp))
            ri.heartbeatHelper(UNLOCK_BUCKET_ID, instant, 0.0, JSONObject(), 0.0)
        }
        
        Log.i(TAG, "Finished processing events, sent $eventsSent session events and ${unlockTimestamps.size} unlock events")
        return eventsSent
    }

    private fun captureAllowed(): Boolean = captureSources(
        vaultReady = !ri.needsVaultRecovery,
        recordingEnabled = AWPreferences(context).isCaptureEnabled(),
        usageAccessGranted = UsageStatsWatcher.isUsageAllowed(context),
        browserOptIn = false,
        accessibilityGranted = false,
        mediaOptIn = false,
        notificationAccessGranted = false,
    ).usageStats



    /**
     * Insert a single session as an individual event (not a heartbeat)
     */
    private fun insertSessionAsEvent(session: AppSession) {
        val startInstant = DateTimeUtils.toInstant(java.util.Date(session.startTime))
        val duration = session.durationSeconds
        val data = session.toEventData()

        // Use insertEvent method to insert as discrete event
        // This prevents merging behavior and treats each session as a separate event
        ri.insertEvent(SESSION_BUCKET_ID, startInstant, duration, data)

        Log.d(TAG, "Inserted one local session event")
    }

    /**
     * Insert session as discrete event with specific timestamp and duration
     */
    fun insertSessionEvent(
        packageName: String,
        appName: String,
        className: String = "",
        startTime: Long,
        durationMs: Long
    ) {
        val session = AppSession(
            packageName = packageName,
            appName = appName,
            className = className,
            startTime = startTime,
            endTime = startTime + durationMs
        )

        ri.createBucketHelper(SESSION_BUCKET_ID, "currentwindow")
        insertSessionAsEvent(session)

        Log.d(TAG, "Inserted one manual session event")
    }

    /**
     * Clear all session events from the bucket (useful for testing)
     */
    fun clearSessionEvents() {
        // Note: There's no direct clear method in RustInterface
        // This is a placeholder for potential future implementation
        Log.w(TAG, "Clear session events not implemented - would require new RustInterface method")
    }

    /**
     * Get count of events in session bucket
     */
    fun getSessionEventCount(): Int {
        val events = ri.getEventsJSON(SESSION_BUCKET_ID)
        return events.length()
    }
}
