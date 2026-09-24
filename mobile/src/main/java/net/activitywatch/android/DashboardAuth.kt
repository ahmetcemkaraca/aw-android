package net.activitywatch.android

import android.content.Context
fun clearLegacyDashboardApiKey(context: Context): Boolean = ConfigManager(context).clearApiKey()
