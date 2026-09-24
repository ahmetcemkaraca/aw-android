package net.activitywatch.android.models

import android.app.usage.UsageEvents
import android.content.Context
import android.content.pm.PackageManager
import org.json.JSONObject
import org.threeten.bp.DateTimeUtils
import org.threeten.bp.Instant

internal fun createUsageStatsEventData(packageName: String, appLabel: String?): JSONObject {
    val data = JSONObject()
    data.put("app", appLabel?.trim()?.takeIf { it.isNotEmpty() } ?: packageName)
    data.put("package", packageName)
    return data
}

data class Event(val timestamp: Instant, val duration: Double = 0.0, val data: JSONObject) {
    companion object {
        fun fromUsageEvent(usageEvent: UsageEvents.Event, context: Context): Event {
            val timestamp = DateTimeUtils.toInstant(java.util.Date(usageEvent.timeStamp))
            val pm = context.packageManager
            val appName = try {
                pm.getApplicationLabel(pm.getApplicationInfo(usageEvent.packageName, 0))?.toString()
            } catch (_: PackageManager.NameNotFoundException) {
                null
            }

            return Event(
                timestamp = timestamp,
                duration = 0.0,
                data = createUsageStatsEventData(usageEvent.packageName, appName)
            )
        }
    }

    override fun toString(): String {
        val event = JSONObject()
        event.put("timestamp", timestamp)
        event.put("duration", duration)
        event.put("data", data)
        return event.toString()
    }
}
