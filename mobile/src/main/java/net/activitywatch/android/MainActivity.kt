package net.activitywatch.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.widget.TextView
import android.view.Menu
import android.view.MenuItem
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.widget.SwitchCompat
import androidx.core.content.ContextCompat
import androidx.core.view.GravityCompat
import androidx.fragment.app.Fragment
import com.google.android.material.navigation.NavigationView
import com.google.android.material.snackbar.Snackbar
import net.activitywatch.android.databinding.ActivityMainBinding
import net.activitywatch.android.fragments.TestFragment
import net.activitywatch.android.fragments.WebUIFragment
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.activitywatch.android.watcher.MediaWatcher
import net.activitywatch.android.watcher.UsageStatsWatcher
import org.json.JSONObject

private const val TAG = "MainActivity"

const val baseURL = "http://127.0.0.1:5600"


class MainActivity : AppCompatActivity(), NavigationView.OnNavigationItemSelectedListener, WebUIFragment.OnFragmentInteractionListener {

    private lateinit var binding: ActivityMainBinding
    private lateinit var preferences: AWPreferences
    private lateinit var recordingSwitch: SwitchCompat
    private lateinit var recordingStatus: TextView
    private var updatingRecordingControl = false
    private var vaultReady = false
    private lateinit var rustInterface: RustInterface

    private val importEntitlement = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null || !::rustInterface.isInitialized) return@registerForActivityResult
        lifecycleScope.launch {
            val response = withContext(Dispatchers.IO) {
                try {
                    val bytes = contentResolver.openInputStream(uri)?.use(::readEntitlementDocument)
                        ?: throw IllegalArgumentException()
                    try {
                        val arguments = JSONObject().put("proof", JSONObject(String(bytes, Charsets.UTF_8)))
                        JSONObject(rustInterface.localNativeCommand("import_entitlement", arguments.toString()))
                    } finally { bytes.fill(0) }
                } catch (_: Exception) { JSONObject().put("error", "The signed entitlement document could not be imported.") }
            }
            showEntitlementStatus(response.optString("error").takeIf { response.has("error") })
        }
    }

    private val requestNotificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (!granted) {
                Log.i(TAG, "POST_NOTIFICATIONS denied; foreground service notification will be suppressed on Android 13+")
            }
        }

    val version: String
        get() {
            return packageManager.getPackageInfo(packageName, 0).versionName ?: "unknown"
        }

    override fun onFragmentInteraction(item: Uri) {
        Log.w(TAG, "URI onInteraction listener not implemented")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        preferences = AWPreferences(this)
        if (preferences.isFirstTime()) {
            Log.i(TAG, "First launch, opening onboarding")
            val intent = Intent(this, OnboardingActivity::class.java)
            startActivity(intent)
            finish()
            return
        }

        // Set up UI
        binding = ActivityMainBinding.inflate(layoutInflater)
        val view = binding.root
        setContentView(view)

        rustInterface = RustInterface(this)
        val rust = rustInterface
        vaultReady = !rust.needsVaultRecovery
        if (!vaultReady) {
            recordingSwitch = findViewById(R.id.recording_switch)
            recordingStatus = findViewById(R.id.recording_status)
            recordingSwitch.isEnabled = false
            recordingStatus.text = getString(R.string.vault_recovery_required)
            val preview = rust.previewLegacyMigration()
            val builder = AlertDialog.Builder(this)
            if (preview.has("error")) {
                builder.setTitle(R.string.vault_recovery_title)
                    .setMessage(R.string.vault_recovery_required)
                    .setPositiveButton(android.R.string.ok, null)
            } else {
                builder.setTitle(R.string.vault_migration_title)
                    .setMessage(getString(
                        R.string.vault_migration_prompt,
                        preview.optLong("buckets"),
                        preview.optLong("events")
                    ))
                    .setNegativeButton(android.R.string.cancel, null)
                    .setPositiveButton("Encrypt data") { _, _ ->
                        lifecycleScope.launch {
                            val migrated = withContext(Dispatchers.IO) { rust.migrateLegacyVault() }
                            if (migrated) recreate() else {
                                AlertDialog.Builder(this@MainActivity)
                                    .setTitle(R.string.vault_recovery_title)
                                    .setMessage(R.string.vault_migration_failed)
                                    .setPositiveButton(android.R.string.ok, null)
                                    .show()
                            }
                        }
                    }
            }
            builder.setCancelable(false).show()
            return
        }

        recordingSwitch = findViewById(R.id.recording_switch)
        recordingStatus = findViewById(R.id.recording_status)
        recordingSwitch.isChecked = preferences.isCaptureEnabled()
        recordingSwitch.setOnCheckedChangeListener { button, enabled ->
            if (updatingRecordingControl) return@setOnCheckedChangeListener
            if (enabled && !UsageStatsWatcher.isUsageAllowed(this)) {
                updatingRecordingControl = true
                button.isChecked = false
                updatingRecordingControl = false
                preferences.setCaptureEnabled(false)
                startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                refreshRecordingStatus()
                return@setOnCheckedChangeListener
            }
            preferences.setCaptureEnabled(enabled)
            val watcher = UsageStatsWatcher(this)
            if (enabled) {
                watcher.setupAlarm()
                lifecycleScope.launch { watcher.sendHeartbeatsSuspend() }
            } else {
                watcher.cancelAlarm()
            }
            MediaWatcher.requestRefresh(this)
            refreshRecordingStatus()
            startService(Intent(this, BackgroundService::class.java).apply {
                action = BackgroundService.ACTION_CAPTURE_STATE_CHANGED
            })
            if (enabled) requestNotificationPermissionWithDisclosure()
        }
        recordingStatus.setOnClickListener {
            if (!UsageStatsWatcher.isUsageAllowed(this)) {
                startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            }
        }
        refreshRecordingStatus()
        MediaWatcher.requestRefresh(this)

        if (preferences.isCaptureEnabled() && UsageStatsWatcher.isUsageAllowed(this)) {
            UsageStatsWatcher(this).setupAlarm()
        }

        binding.navView.setNavigationItemSelectedListener(this)

        // Start the local reports service.
        val serviceIntent = Intent(this, BackgroundService::class.java)
        startForegroundService(serviceIntent)
        requestNotificationPermissionWithDisclosure()

        if (savedInstanceState != null) {
            return
        }
        val firstFragment = WebUIFragment.newInstance(baseURL)
        supportFragmentManager.beginTransaction()
            .add(R.id.fragment_container, firstFragment).commit()

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (binding.drawerLayout.isDrawerOpen(GravityCompat.START)) {
                    binding.drawerLayout.closeDrawer(GravityCompat.START)
                } else {
                    finish()
                }
            }
        })

    }

    override fun onResume() {
        super.onResume()
        if (!vaultReady) return
        refreshRecordingStatus()
        val watcher = UsageStatsWatcher(this)
        watcher.setupAlarm()
        MediaWatcher.requestRefresh(this)
        startService(Intent(this, BackgroundService::class.java).apply {
            action = BackgroundService.ACTION_CAPTURE_STATE_CHANGED
        })

        // Ensures data is always fresh when app is opened,
        // even if it was up to an hour since the last logging-alarm was triggered.
        if (preferences.isCaptureEnabled() && UsageStatsWatcher.isUsageAllowed(this)) {
            lifecycleScope.launch { watcher.sendHeartbeatsSuspend() }
        }
    }

    private fun refreshRecordingStatus() {
        if (!::recordingSwitch.isInitialized || !::recordingStatus.isInitialized) return
        if (!vaultReady) {
            recordingSwitch.isEnabled = false
            recordingStatus.text = getString(R.string.vault_recovery_required)
            return
        }
        val recording = preferences.isCaptureEnabled()
        val usageAccess = UsageStatsWatcher.isUsageAllowed(this)
        val browserAccess = UsageStatsWatcher.isAccessibilityAllowed(this)
        val mediaAccess = MediaWatcher.isNotificationAccessGranted(this)
        val notificationsAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
            || ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        updatingRecordingControl = true
        recordingSwitch.isChecked = recording
        updatingRecordingControl = false
        recordingStatus.text = if (!usageAccess && !recording) {
            getString(R.string.usage_access_missing_manual_mode)
        } else {
            when (captureState(recording, usageAccess)) {
                CaptureState.RECORDING -> getString(R.string.recording_running)
                CaptureState.PAUSED -> getString(R.string.recording_paused)
                CaptureState.PERMISSION_REQUIRED -> getString(R.string.recording_permission_required)
            }
        }
        recordingStatus.isClickable = !usageAccess
        recordingStatus.contentDescription = listOf(
            recordingStatus.text.toString(),
            if (!preferences.isBrowserCaptureEnabled()) "Browser capture off" else if (browserAccess) "Browser access granted" else "Browser capture paused: accessibility access required",
            if (!preferences.isMediaCaptureEnabled()) "Media capture off" else if (mediaAccess) "Media access granted" else "Media capture paused: notification access required",
            if (notificationsAllowed) "Notifications allowed" else "Notifications unavailable"
        ).joinToString(". ")
    }

    private fun requestNotificationPermissionWithDisclosure() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
            || ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            || preferences.hasRequestedNotificationPermission()) return

        preferences.setNotificationPermissionRequested()
        AlertDialog.Builder(this)
            .setTitle(R.string.notification_permission_title)
            .setMessage(R.string.notification_permission_message)
            .setPositiveButton("Continue") { _, _ -> requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS) }
            .setNegativeButton("Not now", null)
            .show()
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        // Inflate the menu; this adds items to the action bar if it is present.
        menuInflater.inflate(R.menu.main, menu)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        // Handle action bar item clicks here. The action bar will
        // automatically handle clicks on the Home/Up button, so long
        // as you specify a parent activity in AndroidManifest.xml.
        return when (item.itemId) {
            R.id.action_entitlement -> {
                showEntitlementStatus()
                true
            }
            R.id.action_sync_settings -> {
                val fragment = WebUIFragment.newInstance("$baseURL/#/settings/sync")
                supportFragmentManager.beginTransaction()
                    .replace(R.id.fragment_container, fragment)
                    .commit()
                true
            }
            else -> super.onOptionsItemSelected(item)
        }
    }

    private fun showEntitlementStatus(importError: String? = null) {
        if (!::rustInterface.isInitialized) return
        lifecycleScope.launch {
            val message = withContext(Dispatchers.IO) {
                val status = try { JSONObject(rustInterface.localNativeCommand("entitlement_status", "{}")) }
                    catch (_: Exception) { JSONObject() }
                val plan = status.optJSONObject("result")
                val summary = if (plan == null) getString(R.string.entitlement_local_access) else {
                    getString(R.string.entitlement_plan_access, plan.optString("plan_id"), plan.optString("access")) + "\n" +
                        getString(if (plan.optBoolean("sync_allowed", false)) R.string.entitlement_sync_feature else R.string.entitlement_no_sync_feature)
                }
                listOfNotNull(importError, summary, getString(R.string.entitlement_local_features),
                    getString(R.string.entitlement_storage_protection, rustInterface.entitlementProtection())).joinToString("\n\n")
            }
            if (isFinishing || isDestroyed) return@launch
            AlertDialog.Builder(this@MainActivity)
                .setTitle(R.string.entitlement_title)
                .setMessage(message)
                .setPositiveButton(R.string.entitlement_import) { _, _ -> importEntitlement.launch(arrayOf("application/json")) }
                .setNegativeButton(android.R.string.ok, null)
                .show()
        }
    }

    override fun onNavigationItemSelected(item: MenuItem): Boolean {
        var fragmentClass: Class<out Fragment>? = null
        var url: String? = null

        // Handle navigation view item clicks here.
        when (item.itemId) {
            R.id.nav_dashboard -> {
                fragmentClass = TestFragment::class.java
            }
            R.id.nav_activity -> {
                fragmentClass = WebUIFragment::class.java
                url = "$baseURL/#/activity/unknown/"
            }
            R.id.nav_buckets -> {
                fragmentClass = WebUIFragment::class.java
                url = "$baseURL/#/buckets/"
            }
            R.id.nav_settings -> {
                fragmentClass = WebUIFragment::class.java
                url = "$baseURL/#/settings/"
            }
            R.id.nav_capture_settings -> {
                startActivity(Intent(this, OnboardingActivity::class.java))
            }
            R.id.nav_send -> {
                Snackbar.make(binding.coordinatorLayout, "The send button was clicked, but it's not yet implemented!", Snackbar.LENGTH_LONG)
                    .setAction("Action", null).show()
            }
        }

        val fragment: Fragment? = try {
            if (fragmentClass === WebUIFragment::class.java && url != null) {
                WebUIFragment.newInstance(url)
            } else {
                fragmentClass?.newInstance()
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }

        if(fragment != null) {
            // Insert the fragment by replacing any existing fragment
            val fragmentManager = supportFragmentManager
            fragmentManager.beginTransaction().replace(R.id.fragment_container, fragment).commit()
        }

        binding.drawerLayout.closeDrawer(GravityCompat.START)
        return true
    }

    override fun onDestroy() {
        super.onDestroy()
    }
}
