package net.activitywatch.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.system.Os
import android.util.Log
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import net.activitywatch.android.models.Event
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.threeten.bp.Instant

private const val TAG = "RustInterface"

class RustInterface(context: Context) {

    private val appContext: Context = context.applicationContext
    private val entitlementStore = EntitlementStore(appContext)
    @Volatile private var vaultUnlocked = false
    val needsVaultRecovery: Boolean
        get() = !vaultUnlocked

    init {
        // NOTE: This doesn't work, probably because I can't get gradle to not strip symbols on
        // release builds
        Os.setenv("RUST_BACKTRACE", "1", true)

        Os.setenv("SQLITE_TMPDIR", appContext.cacheDir.absolutePath, true)

        System.loadLibrary("aw_server")

        initialize()
        installEntitlementSource(entitlementStore)
        setDataDir(appContext.filesDir.absolutePath)
        when (val result = VaultKeyStore.loadOrCreate(appContext, VaultKeyStore.databaseExists(appContext))) {
            is VaultKeyResult.Unlocked -> {
                try {
                    vaultUnlocked = setVaultKey(result.key) && initializeVault()
                } finally {
                    result.key.fill(0)
                }
            }
            VaultKeyResult.NeedsRecovery, VaultKeyResult.Unavailable -> vaultUnlocked = false
        }
    }

    private external fun initialize()
    private external fun installEntitlementSource(source: EntitlementStore): Boolean
    private external fun greeting(pattern: String): String
    private external fun startServer()
    private external fun setDataDir(path: String)
    private external fun setVaultKey(key: ByteArray): Boolean
    private external fun initializeVault(): Boolean
    private external fun nativeGetBuckets(): String
    private external fun nativeCreateBucket(bucket: String): String
    private external fun nativeGetEvents(bucket_id: String, limit: Int): String
    private external fun nativeHeartbeat(bucket_id: String, event: String, pulsetime: Double): String
    private external fun nativeQuery(query: String, timeperiods: String): String
    private external fun nativeAndroidQuery(timeperiods: String): String
    private external fun nativeMigrateHostname(hostname: String): String
    private external fun nativePreviewLegacyMigration(): String
    private external fun nativeMigrateLegacyVault(key: ByteArray, accepted: Boolean): Boolean
    private external fun nativeLocalCommand(command: String, arguments: String): String

    fun getBuckets(): String = if (vaultUnlocked) nativeGetBuckets() else VAULT_ERROR
    fun createBucket(bucket: String): String = if (vaultUnlocked) nativeCreateBucket(bucket) else VAULT_ERROR
    fun getEvents(bucket_id: String, limit: Int): String = if (vaultUnlocked) nativeGetEvents(bucket_id, limit) else VAULT_ERROR
    fun heartbeat(bucket_id: String, event: String, pulsetime: Double): String =
        if (vaultUnlocked) nativeHeartbeat(bucket_id, event, pulsetime) else VAULT_ERROR
    fun query(query: String, timeperiods: String): String =
        if (vaultUnlocked) nativeQuery(query, timeperiods) else VAULT_ERROR
    fun androidQuery(timeperiods: String): String = if (vaultUnlocked) nativeAndroidQuery(timeperiods) else VAULT_ERROR
    fun migrateHostname(hostname: String): String =
        if (vaultUnlocked) nativeMigrateHostname(hostname) else VAULT_ERROR

    fun previewLegacyMigration(): JSONObject = try {
        JSONObject(nativePreviewLegacyMigration())
    } catch (_: JSONException) {
        JSONObject(VAULT_ERROR)
    }

    fun migrateLegacyVault(): Boolean {
        val result = VaultKeyStore.keyForAcceptedMigration(appContext)
        if (result !is VaultKeyResult.Unlocked) return false
        try {
            if (!nativeMigrateLegacyVault(result.key, accepted = true)) return false
            vaultUnlocked = setVaultKey(result.key) && initializeVault()
            return vaultUnlocked
        } finally {
            result.key.fill(0)
        }
    }

    fun localNativeCommand(command: String, arguments: String): String =
        if (vaultUnlocked) nativeLocalCommand(command, arguments) else "{\"error\":\"vault_unavailable\"}"

    fun entitlementProtection(): String = entitlementStore.protection()

    fun isNetworkSyncEnabled(): Boolean {
        if (!vaultUnlocked) return false
        val storedConsent = storedSyncConsentEnabled() ?: return true
        if (!storedConsent) return false
        val token = localAdminSession() ?: return true
        return try {
            val response = localAdminRequest("/api/0/sync/enabled", "GET", token)
            if (response.statusCode in 200..299) JSONObject(response.body).optBoolean("enabled", false)
            else if (response.statusCode in 400..499) false
            else true
        } catch (_: IOException) {
            true
        } catch (_: JSONException) {
            true
        }
    }

    fun runNetworkSync(): JSONObject {
        val response = JSONObject()
        if (!vaultUnlocked) return response.put("success", false).put("retryable", false)
        val token = localAdminSession()
            ?: return response.put("success", false).put("retryable", true)
        return try {
            val result = localAdminRequest("/api/0/sync/run", "POST", token)
            response.put("success", result.statusCode in 200..299)
                .put("retryable", result.statusCode == 408 || result.statusCode == 429 || result.statusCode in 500..599)
        } catch (_: IOException) {
            response.put("success", false).put("retryable", true)
        } catch (_: Exception) {
            response.put("success", false).put("retryable", false)
        }
    }

    private fun storedSyncConsentEnabled(): Boolean? = try {
        val result = JSONObject(nativeLocalCommand("sync_enabled", "{}"))
        if (result.has("error")) null else result.optBoolean("result", false)
    } catch (_: JSONException) {
        null
    }

    private fun localAdminSession(): String? = try {
        val result = JSONObject(nativeLocalCommand("local_session", "{}"))
        if (result.has("error")) null else result.optString("result").takeIf { it.isNotBlank() }
    } catch (_: JSONException) {
        null
    }

    private data class LocalResponse(val statusCode: Int, val body: String)

    @Throws(IOException::class)
    private fun localAdminRequest(path: String, method: String, token: String): LocalResponse {
        val connection = URL("http://127.0.0.1:5600$path").openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 3_000
        connection.readTimeout = 120_000
        connection.instanceFollowRedirects = false
        connection.useCaches = false
        connection.setRequestProperty("Authorization", "Bearer $token")
        connection.setRequestProperty("Accept", "application/json")
        return try {
            val status = connection.responseCode
            val body = if (method == "GET" && status in 200..299) {
                connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            } else ""
            LocalResponse(status, body)
        } finally {
            connection.disconnect()
        }
    }

    fun sayHello(to: String): String {
        return greeting(to)
    }

    fun startServerTask() {
        if (vaultUnlocked && !serverStarted) {
            // check if port 5600 is already in use
            try {
                val socket = java.net.ServerSocket(5600)
                socket.close()
            } catch (e: java.net.BindException) {
                Log.e(TAG, "Port 5600 is already in use, server probably already started")
                return
            }

            serverStarted = true
            val executor = Executors.newSingleThreadExecutor()
            val handler = Handler(Looper.getMainLooper())
            executor.execute {
                // will not block the UI thread

                // Start server
                Log.w(TAG, "Starting server...")
                startServer()

                handler.post {
                    // will run on UI thread after the task is done
                    Log.i(TAG, "Server finished")
                    serverStarted = false
                }
            }
            Log.w(TAG, "Server started")
        }
    }

    fun createBucketHelper(bucket_id: String, type: String, client: String = "aw-android") {
        if (!vaultUnlocked) return
        val context = appContext
        val hostname = getDeviceName(context)
        if (bucket_id in getBucketsJSON().keys().asSequence()) {
            Log.i(TAG, "Bucket with ID '$bucket_id', already existed. Not creating.")
        } else {
            val msg =
                createBucket(
                    """{"id": "$bucket_id", "type": "$type", "hostname": "$hostname", "client": "$client"}"""
                )
            Log.w(TAG, msg)
        }
    }

    /**
     * Send a heartbeat event that may be merged with nearby events.
     *
     * Heartbeats are useful for:
     * - Live tracking where events are sent continuously
     * - Situations where event merging is desired
     *
     * However, for app usage tracking, heartbeats can cause data loss due to:
     * - Events being merged incorrectly
     * - Zero-duration events being created
     * - Significant underreporting (up to 97% data loss observed)
     *
     * @param bucket_id The bucket to send the heartbeat to
     * @param timestamp The event timestamp
     * @param duration The event duration in seconds
     * @param data Event metadata
     * @param pulsetime Time window for merging events (default: 60 seconds)
     */
    fun heartbeatHelper(
        bucket_id: String,
        timestamp: Instant,
        duration: Double,
        data: JSONObject,
        pulsetime: Double = 60.0
    ) {
        if (!vaultUnlocked) return
        val event = Event(timestamp, duration, data)
        val msg = heartbeat(bucket_id, event.toString(), pulsetime)
        // Log.w(TAG, msg)
    }

    /**
     * Insert a discrete event by calling heartbeat() with pulsetime=0, which prevents
     * the server from merging it with adjacent events. Prefer this over heartbeatHelper()
     * when the session duration is already known and should be stored exactly as-is.
     *
     * @param bucket_id The bucket to insert the event into
     * @param timestamp The exact start time of the event
     * @param duration The precise duration in seconds
     * @param data Event metadata (app name, package, etc.)
     */
    fun insertEvent(bucket_id: String, timestamp: Instant, duration: Double, data: JSONObject) {
        if (!vaultUnlocked) return
        val event = Event(timestamp, duration, data)
        val msg = heartbeat(bucket_id, event.toString(), 0.0)
        Log.d(TAG, "insertEvent response: $msg")
    }

    fun getBucketsJSON(): JSONObject {
        if (!vaultUnlocked) return JSONObject()
        // TODO: Handle errors
        val json = JSONObject(getBuckets())
        if (json.length() <= 0) {
            Log.w(TAG, "Length: ${json.length()}")
        }
        return json
    }

    fun getEventsJSON(bucket_id: String, limit: Int = 0): JSONArray {
        if (!vaultUnlocked) return JSONArray()
        // TODO: Handle errors
        val result = getEvents(bucket_id, limit)
        return try {
            JSONArray(result)
        } catch (e: JSONException) {
            Log.e(TAG, "The local activity response could not be parsed")
            JSONArray()
        }
    }

    fun getDeviceName(context: Context): String {
        val raw = Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: android.os.Build.DEVICE
            ?: "unknown"
        return raw.trim()
            .lowercase(java.util.Locale.ROOT)
            .replace(Regex("[^a-z0-9_-]+"), "_")
            .trim('_')
            .ifEmpty { "unknown" }
    }

    companion object {
        private const val VAULT_ERROR = "{\"error\":\"vault_unavailable\"}"
        @Volatile var serverStarted = false
    }

}
