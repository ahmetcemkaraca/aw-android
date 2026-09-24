package net.activitywatch.android

import android.content.Context
import android.util.Log
import java.io.File
import java.io.IOException

private const val TAG = "ConfigManager"

/** Removes an obsolete local API key without changing other Rust server settings. */
class ConfigManager(context: Context) {
    private val configFile = File(context.filesDir, "config.toml")

    fun clearApiKey(): Boolean {
        if (!configFile.isFile) return true
        return try {
            val current = configFile.readText()
            val updated = removeLegacyApiKeyFromConfig(current)
            if (updated == current) return true
            val temporary = File(configFile.parent, "${configFile.name}.tmp")
            temporary.writeText(updated)
            if (!temporary.renameTo(configFile)) {
                temporary.delete()
                throw IOException("Could not replace local server configuration")
            }
            true
        } catch (error: Exception) {
            Log.w(TAG, "Could not remove the legacy dashboard credential")
            false
        }
    }
}

internal fun removeLegacyApiKeyFromConfig(content: String): String {
    val authSection = Regex("""(?m)^\[auth\].*?(?=^\[|\z)""", RegexOption.DOT_MATCHES_ALL)
        .find(content) ?: return content
    val withoutKey = Regex("""(?m)^[ \t]*api_key[ \t]*=.*(?:\r?\n|$)""")
        .replace(authSection.value, "")
    return content.replaceRange(authSection.range, withoutKey)
}
