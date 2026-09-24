import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ANDROID_NS = '{http://schemas.android.com/apk/res/android}'


class MobilePrivacyTest(unittest.TestCase):
    def test_manifest_disables_os_backup_and_broad_package_inventory(self):
        manifest = ET.parse(ROOT / 'mobile/src/main/AndroidManifest.xml').getroot()
        application = manifest.find('application')
        permissions = {
            node.get(ANDROID_NS + 'name')
            for node in manifest.findall('uses-permission')
        }
        self.assertEqual(application.get(ANDROID_NS + 'allowBackup'), 'false')
        self.assertNotIn('android.permission.QUERY_ALL_PACKAGES', permissions)
        self.assertNotIn('android.permission.SCHEDULE_EXACT_ALARM', permissions)
        self.assertEqual(application.get(ANDROID_NS + 'fullBackupContent'), '@xml/backup_rules')
        self.assertEqual(application.get(ANDROID_NS + 'dataExtractionRules'), '@xml/data_extraction_rules')
        legacy = ET.parse(ROOT / 'mobile/src/main/res/xml/backup_rules.xml').getroot()
        modern = ET.parse(ROOT / 'mobile/src/main/res/xml/data_extraction_rules.xml').getroot()
        self.assertTrue(legacy.findall('exclude'))
        for section in ('cloud-backup', 'device-transfer'):
            excludes = modern.find(section).findall('exclude')
            self.assertTrue(excludes, f'{section} must explicitly exclude app data')

    def test_upstream_release_credentials_are_not_available_in_plaintext(self):
        self.assertFalse((ROOT / 'android.jks').exists())
        self.assertFalse((ROOT / 'fastlane/api-8546008605074111507-287154-450dc77b365f.json').exists())

    def test_android_candidate_has_no_inherited_release_automation_or_signing_blobs(self):
        workflows = ROOT / '.github/workflows'
        self.assertFalse((workflows / 'release.yml').exists())
        build_workflow = (workflows / 'build.yml').read_text()
        for forbidden in (
            'tags:',
            'release-fastlane:',
            'upload_to_play_store',
            'KEY_ANDROID_JKS',
            'KEY_FASTLANE_API',
            'android.jks.age',
            'refs/tags/v',
        ):
            self.assertNotIn(forbidden, build_workflow)
        self.assertIn('  test:', build_workflow)
        self.assertFalse((ROOT / 'android.jks.age').exists())
        fastlane = ROOT / 'fastlane'
        self.assertFalse(list(fastlane.glob('*.age')))
        self.assertFalse(list(fastlane.glob('*.enc')))
        appfile = (fastlane / 'Appfile').read_text()
        self.assertNotIn('json_key_file', appfile)
        self.assertFalse((fastlane / 'Fastfile').exists())
        self.assertFalse((fastlane / 'README.md').exists())
        metadata = fastlane / 'metadata/android/en-US'
        for filename in ('title.txt', 'short_description.txt', 'full_description.txt'):
            self.assertNotIn('ActivityWatch', (metadata / filename).read_text())
        self.assertIn('not been approved for publication', (metadata / 'full_description.txt').read_text())

    def test_user_copy_uses_peakactivity_identity_and_does_not_claim_sync_is_local(self):
        strings = (ROOT / 'mobile/src/main/res/values/strings.xml').read_text()
        manifest = (ROOT / 'mobile/src/main/AndroidManifest.xml').read_text()
        self.assertIn('<string name="app_name">PeakActivity</string>', strings)
        self.assertNotIn('ActivityWatch', strings)
        self.assertNotIn('All data stays on-device', manifest)

    def test_permission_denial_keeps_manual_mode_and_source_switches_fail_closed(self):
        main = (ROOT / 'mobile/src/main/java/net/activitywatch/android/MainActivity.kt').read_text()
        prefs = (ROOT / 'mobile/src/main/java/net/activitywatch/android/AWPreferences.kt').read_text()
        browser = (ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/WebWatcher.kt').read_text()
        media = (ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/MediaWatcher.kt').read_text()
        manifest = (ROOT / 'mobile/src/main/AndroidManifest.xml').read_text()
        self.assertIn('if (preferences.isFirstTime())', main)
        self.assertNotIn('|| !UsageStatsWatcher.isUsageAllowed(this)', main)
        self.assertIn('R.string.usage_access_missing_manual_mode', main)
        self.assertIn('getBoolean("browserCaptureEnabled", false)', prefs)
        self.assertIn('getBoolean("mediaCaptureEnabled", false)', prefs)
        self.assertIn('browserOptIn = preferences.isBrowserCaptureEnabled()', browser)
        self.assertIn('accessibilityGranted = UsageStatsWatcher.isAccessibilityAllowed(applicationContext)', browser)
        self.assertIn('isMediaCaptureEnabled()', media)
        self.assertNotIn('SyncSettingsActivity', manifest)
        self.assertNotIn('isSyncEnabled', prefs)

    def test_mobile_data_inventory_matches_separate_local_sources(self):
        import json

        inventory = json.loads((ROOT / 'docs/mobile-data-inventory.json').read_text())
        sources = {source['id']: source for source in inventory['sources']}
        self.assertIn('android_usage_stats', sources)
        self.assertIn('browser_accessibility', sources)
        self.assertIn('media_sessions', sources)
        self.assertIn('supported_browser_url', sources['browser_accessibility']['fields'])
        self.assertEqual(inventory['storage']['os_backup'], 'disabled')
        self.assertEqual(inventory['storage']['analytics_or_advertising'], 'none')
        self.assertEqual(inventory['release_review']['play_data_safety_form'], 'not approved')

    def test_usage_stats_share_sensitive_app_exclusion_before_storage(self):
        android_event = (ROOT / 'mobile/src/main/java/net/activitywatch/android/models/Event.kt').read_text()
        rust_capture = (ROOT.parent / 'aw-server-rust/aw-models/src/capture.rs').read_text()
        rust_worker = (ROOT.parent / 'aw-server-rust/aw-datastore/src/worker.rs').read_text()
        self.assertIn('createUsageStatsEventData(usageEvent.packageName, appName)', android_event)
        self.assertIn('excluded_apps.iter().any(|excluded| app.contains(excluded))', rust_capture)
        self.assertIn('bucket == "aw-watcher-android"', rust_capture)
        self.assertIn('policy.filter(bucket, event.clone(), capture)?', rust_worker)

    def test_shared_permission_matrix_gates_usage_browser_and_media_writes(self):
        policy = (ROOT / 'mobile/src/main/java/net/activitywatch/android/CaptureState.kt').read_text()
        sources = [
            ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/UsageStatsWatcher.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/SessionEventWatcher.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/WebWatcher.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/MediaWatcher.kt',
        ]
        self.assertIn('fun captureSources(', policy)
        for path in sources:
            self.assertIn('captureSources(', path.read_text(), path.name)
        self.assertIn('isAccessibilityAllowed(applicationContext)', sources[2].read_text())
        self.assertIn('isNotificationAccessGranted(applicationContext)', sources[3].read_text())

    def test_capture_logs_do_not_write_activity_content(self):
        sources = [
            ROOT / 'mobile/src/main/java/net/activitywatch/android/RustInterface.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/models/Event.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/data/SessionModels.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/UsageStatsWatcher.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/parser/SessionParser.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/WebWatcher.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/MediaWatcher.kt',
            ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/SessionEventWatcher.kt',
        ]
        source = '\n'.join(path.read_text() for path in sources)
        for forbidden in (
            'Registered event: $data',
            'Last event: $lastEvent',
            'accessibility tree:',
            'Media event: $playbackState',
            'includeClassname = true',
            'MATCH_UNINSTALLED_PACKAGES',
            'put("classname"',
            'Inserted session event for ${session.appName}',
            'Session: $appName',
            'Url: $it, browser: $newBrowser',
            'Title: $newWindowTitle',
            'forEachNode(root)',
        ):
            self.assertNotIn(forbidden, source)

    def test_vault_key_path_never_falls_back_to_plaintext(self):
        key_store = (ROOT / 'mobile/src/main/java/net/activitywatch/android/VaultKeyStore.kt').read_text()
        rust = (ROOT.parent / 'aw-server-rust/aw-server/src/android/mod.rs').read_text()
        build = (ROOT.parent / 'aw-server-rust/compile-android.sh').read_text()
        self.assertIn('AndroidKeyStore', key_store)
        self.assertIn('AES/GCM/NoPadding', key_store)
        self.assertIn('VaultKeyAction.RECOVERY', key_store)
        self.assertIn('Datastore::open_encrypted', rust)
        self.assertNotIn('Datastore::new(db_dir, false)', rust)
        unwrap = key_store.split('private fun unwrap(', 1)[1].split('private fun loadExistingWrappingKey', 1)[0]
        self.assertIn('loadExistingWrappingKey()', unwrap)
        self.assertNotIn('wrappingKeyForFirstUse()', unwrap)
        initializer = rust.split('Java_net_activitywatch_android_RustInterface_initializeVault', 1)[1]
        self.assertIn('Ok(_) => JNI_TRUE', initializer)
        self.assertIn('Err(_) => JNI_FALSE', initializer)
        self.assertIn('--no-default-features --features encryption-vendored', build)
        self.assertIn('result.key.fill(0)', (ROOT / 'mobile/src/main/java/net/activitywatch/android/RustInterface.kt').read_text())

    def test_legacy_vault_migration_requires_explicit_acceptance(self):
        main = (ROOT / 'mobile/src/main/java/net/activitywatch/android/MainActivity.kt').read_text()
        bridge = (ROOT / 'mobile/src/main/java/net/activitywatch/android/RustInterface.kt').read_text()
        vault = (ROOT.parent / 'aw-server-rust/aw-datastore/src/vault.rs').read_text()
        rust = (ROOT.parent / 'aw-server-rust/aw-server/src/android/mod.rs').read_text()
        self.assertIn('vault_migration_prompt', main)
        self.assertIn('setPositiveButton("Encrypt data")', main)
        self.assertIn('accepted = true', bridge)
        self.assertIn('pub fn preview_plaintext', vault)
        self.assertIn('encrypted_copy(path, None, &staged, key)?', vault)
        self.assertIn('fs::rename(&staged, path)', vault)
        self.assertIn('if accepted != JNI_TRUE', rust)

    def test_dashboard_uses_origin_limited_local_sessions_without_url_keys(self):
        main = (ROOT / 'mobile/src/main/java/net/activitywatch/android/MainActivity.kt').read_text()
        fragment = (ROOT / 'mobile/src/main/java/net/activitywatch/android/fragments/WebUIFragment.kt').read_text()
        manifest = (ROOT / 'mobile/src/main/AndroidManifest.xml').read_text()
        menu = (ROOT / 'mobile/src/main/res/menu/activity_main_drawer.xml').read_text()
        rust = (ROOT.parent / 'aw-server-rust/aw-server/src/android/mod.rs').read_text()
        self.assertNotIn('authenticatedUrl', main)
        self.assertNotIn('buildDashboardUrl', main)
        self.assertNotIn('ensureDashboardApiKey', main)
        self.assertNotIn('.AuthSettingsActivity', manifest)
        self.assertNotIn('nav_auth_settings', menu)
        background = (ROOT / 'mobile/src/main/java/net/activitywatch/android/BackgroundService.kt').read_text()
        interface = (ROOT / 'mobile/src/main/java/net/activitywatch/android/RustInterface.kt').read_text()
        activity = (ROOT / 'mobile/src/main/java/net/activitywatch/android/MainActivity.kt').read_text()
        self.assertIn('clearLegacyDashboardApiKey(this)', background)
        self.assertIn('WebViewCompat.addWebMessageListener', fragment)
        self.assertIn('setOf("http://127.0.0.1:5600")', fragment)
        self.assertIn('!isMainFrame || !isTrustedDashboardOrigin', fragment)
        self.assertNotIn('addJavascriptInterface', fragment)
        self.assertIn('server_config.auth.sessions = Some(local_sessions())', rust)
        self.assertIn('server_config.auth.api_key = None', rust)
        self.assertIn('local_sessions().mint(Scope::Admin)', rust)
        self.assertNotIn('aw-android-query', rust)
        self.assertIn('Java_net_activitywatch_android_RustInterface_nativeLocalCommand', rust)
        self.assertIn('fun localNativeCommand(command: String, arguments: String)', interface)
        self.assertIn('WebUIFragment.newInstance("$baseURL/#/settings/sync")', activity)
        self.assertNotIn('SyncSettingsActivity', manifest)
        sync_store = (ROOT.parent / 'aw-webui/src/stores/sync.ts').read_text()
        self.assertIn('invokeAndroidNative(command, args)', sync_store)

    def test_resume_rechecks_permissions_and_stops_revoked_sources(self):
        main = (ROOT / 'mobile/src/main/java/net/activitywatch/android/MainActivity.kt').read_text()
        watcher = (ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/UsageStatsWatcher.kt').read_text()
        media = (ROOT / 'mobile/src/main/java/net/activitywatch/android/watcher/MediaWatcher.kt').read_text()
        self.assertIn('watcher.setupAlarm()', main)
        self.assertIn('MediaWatcher.requestRefresh(this)', main)
        self.assertIn('UsageStatsWatcher.isAccessibilityAllowed(this)', main)
        self.assertIn('MediaWatcher.isNotificationAccessGranted(this)', main)
        self.assertIn('POST_NOTIFICATIONS', main)
        self.assertIn('cancelAlarm()', watcher)
        self.assertIn('preferences.isMediaCaptureEnabled()', media)
        self.assertIn('&& isNotificationAccessGranted(context)', media)

    def test_foreground_status_is_truthful_and_sync_stays_closed(self):
        service = (ROOT / 'mobile/src/main/java/net/activitywatch/android/BackgroundService.kt').read_text()
        manifest = (ROOT / 'mobile/src/main/AndroidManifest.xml').read_text()
        sync_view = (ROOT.parent / 'aw-webui/src/views/settings/SyncSettings.vue').read_text()
        self.assertIn('ServiceCompat.startForeground(', service)
        self.assertIn('R.string.service_starting', service)
        self.assertIn('if (rustInterface.needsVaultRecovery)', service)
        self.assertNotIn('SyncScheduler', service)
        self.assertNotIn('SyncAlarmReceiver', manifest)
        self.assertIn('cancelLegacySyncAlarm()', service)
        self.assertIn('net.activitywatch.android.SYNC_ALARM', service)
        self.assertFalse((ROOT / 'mobile/src/main/java/net/activitywatch/android/SyncInterface.kt').exists())
        self.assertNotIn('libaw_sync', (ROOT / 'Makefile').read_text())
        android_build = (ROOT.parent / 'aw-server-rust/compile-android.sh').read_text()
        self.assertNotIn('cargo build -p aw-sync', android_build)
        worker = (ROOT / 'mobile/src/main/java/net/activitywatch/android/workers/SyncWorker.kt').read_text()
        self.assertNotIn('SyncInterface', worker)
        self.assertIn('isNetworkSyncEnabled()', worker)
        self.assertLess(worker.index('isNetworkSyncEnabled()'), worker.index('runNetworkSync()'))
        self.assertIn('retryable', worker)
        self.assertIn('Result.retry()', worker)
        self.assertIn('E2EE network sync stays off', manifest)
        self.assertNotIn('Android network sync remains off until the signed E2EE relay worker', sync_view)

    def test_sync_worker_uses_one_connected_unique_job_and_never_copies_files(self):
        service = (ROOT / 'mobile/src/main/java/net/activitywatch/android/BackgroundService.kt').read_text()
        worker = (ROOT / 'mobile/src/main/java/net/activitywatch/android/workers/SyncWorker.kt').read_text()
        interface = (ROOT / 'mobile/src/main/java/net/activitywatch/android/RustInterface.kt').read_text()
        self.assertIn('fun syncServerCanStart(', worker)
        self.assertIn('fun syncShouldRetry(', worker)
        self.assertLess(worker.index('isNetworkSyncEnabled()'), worker.index('startServerTask()'))
        self.assertIn('setRequiredNetworkType(androidx.work.NetworkType.CONNECTED)', service)
        self.assertIn('"SyncWorker",', service)
        self.assertEqual(service.count('"SyncWorker",'), 1)
        self.assertIn('fun isNetworkSyncEnabled(): Boolean', interface)
        self.assertIn('fun runNetworkSync(): JSONObject', interface)
        self.assertIn('nativeLocalCommand("local_session", "{}")', interface)
        self.assertIn('setRequestProperty("Authorization", "Bearer $token")', interface)
        self.assertNotIn('Log.d(TAG, token)', interface)
        self.assertNotIn('responseBody', worker)
        for forbidden in ('SAF', 'ACTION_OPEN_DOCUMENT', 'ACTION_CREATE_DOCUMENT', 'FileInputStream', 'copyTo('):
            self.assertNotIn(forbidden, worker)

    def test_ios_companion_is_manual_first_and_uses_only_shared_opaque_vectors(self):
        import plistlib
        import xml.etree.ElementTree as ET

        project = ROOT / 'ios-companion'
        xcode_project = project / 'PeakActivityCompanion.xcodeproj'
        app = xcode_project / 'project.pbxproj'
        scheme = xcode_project / 'xcshareddata/xcschemes/PeakActivityCompanion.xcscheme'
        entry = project / 'PeakActivityCompanion/PeakActivityCompanionApp.swift'
        view = project / 'PeakActivityCompanion/ContentView.swift'
        store = project / 'PeakActivityCompanion/CompanionStore.swift'
        model = project / 'PeakActivityCompanion/ManualReport.swift'
        vault = project / 'PeakActivityCompanion/EncryptedCompanionVault.swift'
        info_path = project / 'PeakActivityCompanion/Info.plist'
        entitlements_path = project / 'PeakActivityCompanion/PeakActivityCompanion.entitlements'
        vector = project / 'PeakActivityCompanionTests/Fixtures/sync-recovery-v1.json'
        self.assertTrue(app.is_file(), 'limited iOS SwiftUI project is missing')
        self.assertTrue(entry.is_file() and view.is_file() and store.is_file() and model.is_file() and vault.is_file())
        self.assertTrue(ET.parse(scheme).find('.//TestableReference') is not None)
        self.assertIn('PeakActivityCompanionTests.xctest', app.read_text())
        self.assertEqual(plistlib.loads(info_path.read_bytes())['CFBundleDisplayName'], 'PeakActivity Companion')
        self.assertTrue(plistlib.loads(entitlements_path.read_bytes())['com.apple.developer.family-controls'])
        swift = '\n'.join(path.read_text() for path in (entry, view, store, model, vault))
        self.assertIn('.familyActivityPicker(', view.read_text())
        self.assertIn('store.beginFamilyControlFlow()', view.read_text())
        self.assertIn('requestAuthorization(for: .individual)', store.read_text())
        self.assertIn('FamilyActivitySelection', swift)
        self.assertNotIn('.applications', swift)
        self.assertNotIn('.webDomains', swift)
        capture_code = '\n'.join(path.read_text() for path in (view, store, model))
        self.assertNotIn('bundleIdentifier', capture_code)
        self.assertNotIn('applicationTokens', capture_code)
        self.assertNotIn('URLSession', swift)
        self.assertNotIn('URLRequest', swift)
        self.assertIn('kSecAttrAccessibleWhenUnlockedThisDeviceOnly', vault.read_text())
        self.assertIn('FileProtectionType.complete', vault.read_text())
        self.assertTrue(vector.is_file())
        rust_vector = ROOT.parent / 'aw-server-rust/aw-sync-e2ee/test-vectors/sync-recovery-v1.json'
        self.assertEqual(vector.read_bytes(), rust_vector.read_bytes())

    def test_android_sync_controls_use_shared_encrypted_backend(self):
        rust_sync = (ROOT.parent / 'aw-server-rust/aw-server/src/sync_control.rs').read_text()
        rust_bridge = (ROOT.parent / 'aw-server-rust/aw-server/src/android/mod.rs').read_text()
        datastore = (ROOT.parent / 'aw-server-rust/aw-datastore/src/worker.rs').read_text()
        webview = (ROOT / 'mobile/src/main/java/net/activitywatch/android/fragments/WebUIFragment.kt').read_text()
        store = (ROOT.parent / 'aw-webui/src/stores/sync.ts').read_text()
        self.assertIn('aw_sync_e2ee', rust_sync)
        self.assertIn('create_sync_pairing', rust_sync)
        self.assertIn('create_sync_recovery_kit', rust_sync)
        self.assertIn('accept_sync_key_transfer', rust_sync)
        self.assertIn('confirm_sync_recovery_saved', rust_sync)
        self.assertIn('rotate_sync_keys', rust_sync)
        self.assertIn('userAccepted,', store)
        self.assertIn('args.get("userAccepted")', rust_sync)
        self.assertIn('restore_sync_recovery_data', datastore)
        self.assertIn('nativeLocalCommand', rust_bridge)
        self.assertIn('rust.localNativeCommand(command, arguments)', webview)
        self.assertIn('invokeAndroidNative(command, args)', store)


if __name__ == '__main__':
    unittest.main()
