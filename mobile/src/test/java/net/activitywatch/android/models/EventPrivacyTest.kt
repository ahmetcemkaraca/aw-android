package net.activitywatch.android.models

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import net.activitywatch.android.data.AppSession

class EventPrivacyTest {
    @Test
    fun `usage event contains app and package but no activity class`() {
        val data = createUsageStatsEventData("com.example.editor", "Editor")

        assertEquals("Editor", data.getString("app"))
        assertEquals("com.example.editor", data.getString("package"))
        assertFalse(data.has("classname"))
    }

    @Test
    fun `hidden app label falls back to package id`() {
        val data = createUsageStatsEventData("com.example.hidden", null)

        assertEquals("com.example.hidden", data.getString("app"))
        assertEquals("com.example.hidden", data.getString("package"))
    }

    @Test
    fun `session export omits the internal activity class name`() {
        val data = AppSession(
            packageName = "com.example.editor",
            appName = "Editor",
            className = "SensitiveDocumentActivity",
            startTime = 1000,
            endTime = 2000,
        ).toEventData()

        assertEquals("Editor", data.getString("app"))
        assertEquals("com.example.editor", data.getString("package"))
        assertFalse(data.has("classname"))
    }
}
