package net.activitywatch.android

import android.content.Context
import android.content.SharedPreferences

class AWPreferences(context: Context) {
    private val sharedPreferences: SharedPreferences =
        context.getSharedPreferences("AWPreferences", Context.MODE_PRIVATE)

    // To check if it is the first time the app is being run
    // Set to false when user finishes onboarding
    fun isFirstTime(): Boolean {
        return sharedPreferences.getBoolean("isFirstTime", true)
    }

    // To set the first time flag to false after the first run
    fun setFirstTimeRunFlag() {
        val editor = sharedPreferences.edit()
        editor.putBoolean("isFirstTime", false)
        editor.apply()
    }

    // Optional: To reset the first time flag to true (for debugging, perhaps)
    fun resetFirstTimeRunFlag() {
        val editor = sharedPreferences.edit()
        editor.putBoolean("isFirstTime", true)
        editor.apply()
    }

    // To check if the hostname migration has already been run
    fun hasMigratedHostname(): Boolean {
        return sharedPreferences.getBoolean("hasMigratedHostname", false)
    }

    // To mark the hostname migration as done so it won't run again
    fun setHostnameMigrated() {
        sharedPreferences.edit().putBoolean("hasMigratedHostname", true).apply()
    }

    fun hasRequestedNotificationPermission(): Boolean {
        return sharedPreferences.getBoolean("hasRequestedNotificationPermission", false)
    }

    fun setNotificationPermissionRequested() {
        sharedPreferences.edit().putBoolean("hasRequestedNotificationPermission", true).apply()
    }

    // Existing installations preserve their prior always-on behavior until a user changes it.
    // New installs explicitly choose Start in onboarding; no stored choice means paused.
    fun isCaptureEnabled(): Boolean {
        return sharedPreferences.getBoolean("captureEnabled", !isFirstTime())
    }

    fun setCaptureEnabled(enabled: Boolean) {
        sharedPreferences.edit().putBoolean("captureEnabled", enabled).apply()
    }

    fun isBrowserCaptureEnabled(): Boolean {
        return sharedPreferences.getBoolean("browserCaptureEnabled", false)
    }

    fun setBrowserCaptureEnabled(enabled: Boolean) {
        sharedPreferences.edit().putBoolean("browserCaptureEnabled", enabled).apply()
    }

    fun isMediaCaptureEnabled(): Boolean {
        return sharedPreferences.getBoolean("mediaCaptureEnabled", false)
    }

    fun setMediaCaptureEnabled(enabled: Boolean) {
        sharedPreferences.edit().putBoolean("mediaCaptureEnabled", enabled).apply()
    }

}
