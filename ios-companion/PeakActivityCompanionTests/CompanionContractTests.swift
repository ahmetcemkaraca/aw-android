import CryptoKit
import FamilyControls
import Foundation
import Security
import XCTest
@testable import PeakActivityCompanion

final class CompanionContractTests: XCTestCase {
    func testFeatureListCannotImplyNetworkSyncAccess() throws {
        let bytes = Data(#"{"plan_id":"plus","feature_ids":["e2ee-sync"],"expires_at":200,"grace_until":300,"access":"current","sync_allowed":false}"#.utf8)
        let status = try JSONDecoder().decode(NativeEntitlementStatus.self, from: bytes)
        XCTAssertTrue(status.feature_ids.contains("e2ee-sync"))
        XCTAssertFalse(status.sync_allowed)
        let missingDecision = Data(#"{"plan_id":"plus","feature_ids":["e2ee-sync"],"expires_at":200,"grace_until":300,"access":"current"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeEntitlementStatus.self, from: missingDecision))
    }

    func testEntitlementProofAndGlobalFloorRemainSeparateFromActivity() throws {
        let service = "peakactivity-entitlement-test-\(UUID().uuidString)"
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
        let source = EntitlementStore(service: service)
        XCTAssertNil(try source.load())
        XCTAssertEqual(try source.floor(scope: EntitlementStore.revocationScope), 0)
        try source.save(Data("signed-document".utf8))
        try source.advance(scope: EntitlementStore.revocationScope, sequence: UInt64.max)
        let reopened = EntitlementStore(service: service)
        XCTAssertEqual(try reopened.load(), Data("signed-document".utf8))
        XCTAssertEqual(try reopened.floor(scope: EntitlementStore.revocationScope), UInt64.max)
        XCTAssertThrowsError(try source.advance(scope: EntitlementStore.revocationScope, sequence: 2))
        try reopened.save(Data("restored-older-document".utf8))
        XCTAssertEqual(try source.floor(scope: EntitlementStore.revocationScope), UInt64.max)
        XCTAssertThrowsError(try source.floor(scope: "activity-account"))
        XCTAssertThrowsError(try source.save(Data(count: EntitlementStore.maximumProofBytes + 1)))

        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "signed-proof-v1",
            kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let item = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testMalformedSecureCheckpointCannotBecomeZero() throws {
        let service = "peakactivity-entitlement-test-\(UUID().uuidString)"
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "revocation-floor-v1",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false, kSecValueData as String: Data([1])]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try EntitlementStore(service: service).floor(scope: EntitlementStore.revocationScope))
    }

    @MainActor
    func testForegroundControlsKeepEmptyTrustOffAndClearRestoreInputsOnDetach() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = "peakactivity-test-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: directory)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        let vault = try EncryptedCompanionVault(fileURL: directory.appendingPathComponent("local.bin"), keychainService: service)
        let entry = try ManualActivityEntry(startedAt: .now, durationSeconds: 600, note: "Never sent")
        let original = CompanionVaultState(entries: [entry], familyActivitySelection: FamilyActivitySelection())
        try vault.save(original)
        let client = try await NativeSyncClient.open(vault: vault)
        let model = CompanionSyncStore()
        model.setLocalEntries([entry])
        await model.attach(client)
        XCTAssertTrue(model.available)
        XCTAssertEqual(model.network?.egress.trusted_policy_keys, 0)
        XCTAssertEqual(model.network?.sync.enabled, false)
        XCTAssertNil(model.entitlement)
        XCTAssertTrue(model.destinations.isEmpty)
        let result = try await client.runSyncOnce()
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.retryable)
        try model.importRecoveryKit(Data("{\"schema_version\":1}".utf8))
        try model.importSnapshot(Data("{\"schema_version\":1}".utf8))
        model.restorePhrase = "Sensitive unfinished phrase"
        let session = model.sessionToken
        let previousFile = model.beginFileOperation()
        XCTAssertTrue(model.acceptsFileCallback(session, operation: previousFile))
        let currentFile = model.beginFileOperation()
        XCTAssertFalse(model.acceptsFileCallback(session, operation: previousFile))
        XCTAssertTrue(model.acceptsFileCallback(session, operation: currentFile))
        model.detach()
        XCTAssertFalse(model.acceptsFileCallback(session, operation: currentFile))
        await model.attach(client)
        XCTAssertFalse(model.acceptsFileCallback(session, operation: currentFile))
        model.detach()
        XCTAssertEqual(model.restorePhrase, "")
        XCTAssertNil(model.restorePreview)
        XCTAssertFalse(model.canPreviewRestore)
        XCTAssertNil(model.network)
        XCTAssertEqual(try vault.load(), original)
        let paused = await client.pause()
        XCTAssertTrue(paused)
        let closed = await client.close()
        XCTAssertTrue(closed)
    }

    func testLocalReportAggregatesOnlyManualEntriesForTheSelectedDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 9)))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let entries = [
            try ManualActivityEntry(startedAt: firstDay, durationSeconds: 900, note: "Planning"),
            try ManualActivityEntry(startedAt: firstDay.addingTimeInterval(3600), durationSeconds: 1200, note: "Review"),
            try ManualActivityEntry(startedAt: nextDay, durationSeconds: 1800, note: "Next day"),
        ]

        let report = LocalReportSummary.make(entries: entries, on: firstDay, calendar: calendar)

        XCTAssertEqual(report.entryCount, 2)
        XCTAssertEqual(report.totalDurationSeconds, 2100)
    }

    func testManualEntryRejectsInvalidDurationAndOversizeNotes() {
        XCTAssertThrowsError(try ManualActivityEntry(startedAt: .now, durationSeconds: 0, note: "x"))
        XCTAssertThrowsError(try ManualActivityEntry(startedAt: .now, durationSeconds: 86_401, note: "x"))
        XCTAssertThrowsError(try ManualActivityEntry(startedAt: .now, durationSeconds: 60, note: String(repeating: "x", count: 501)))
    }

    func testEncryptedLocalStateRoundTripsOpaqueFamilyActivitySelection() throws {
        let key = SymmetricKey(size: .bits256)
        let selection = FamilyActivitySelection()
        let entry = try ManualActivityEntry(startedAt: .now, durationSeconds: 600, note: "Private local note")
        let state = CompanionVaultState(entries: [entry], familyActivitySelection: selection)

        let envelope = try CompanionVaultCipher.seal(state, key: key)
        XCTAssertFalse(String(data: envelope, encoding: .utf8)?.contains("Private local note") ?? false)
        let restored = try CompanionVaultCipher.open(envelope, key: key, as: CompanionVaultState.self)

        XCTAssertEqual(restored.entries, [entry])
        XCTAssertEqual(restored.familyActivitySelection, selection)
    }

    func testEncryptedLocalStateRejectsModifiedCiphertext() throws {
        let key = SymmetricKey(size: .bits256)
        let envelope = try CompanionVaultCipher.seal(
            CompanionVaultState(entries: [], familyActivitySelection: nil), key: key,
        )
        var changed = envelope
        changed[changed.index(before: changed.endIndex)] ^= 1
        XCTAssertThrowsError(try CompanionVaultCipher.open(changed, key: key, as: CompanionVaultState.self))
    }

    func testExistingVaultWithoutKeyFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("existing-vault.bin")
        try Data([0x01, 0x02, 0x03]).write(to: file)
        let vault = try EncryptedCompanionVault(fileURL: file, keychainService: UUID().uuidString)

        XCTAssertThrowsError(try vault.load()) { error in
            guard case CompanionVaultError.keyMissing = error else {
                return XCTFail("Expected the existing vault to fail closed when its key is missing")
            }
        }
    }

    func testSharedRecoveryVectorKeepsTheRustCryptoProfile() throws {
        let url = try XCTUnwrap(Bundle(for: CompanionContractTests.self).url(forResource: "sync-recovery-v1", withExtension: "json"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let profile = try XCTUnwrap(value["profile"] as? [String: Any])

        XCTAssertEqual(profile["kdf"] as? String, "argon2id-v19")
        XCTAssertEqual(profile["aead"] as? String, "XChaCha20-Poly1305")
        XCTAssertEqual(profile["nonce_bytes"] as? Int, 24)
        XCTAssertEqual(profile["chunk_limit_bytes"] as? Int, 1_048_576)
    }

    func testNativeBridgeKeepsSyncOffAndPreservesExistingManualState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = "peakactivity-test-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: directory)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        let vault = try EncryptedCompanionVault(fileURL: directory.appendingPathComponent("local-vault.bin"), keychainService: service)
        let entry = try ManualActivityEntry(startedAt: .now, durationSeconds: 600, note: "Local only")
        let state = CompanionVaultState(entries: [entry], familyActivitySelection: FamilyActivitySelection())
        try vault.save(state)
        let client = try await NativeSyncClient.open(vault: vault)
        let enabled = try await client.invoke("sync_enabled", as: Bool.self)
        XCTAssertFalse(enabled)
        let cancelled = try await client.invoke("cancel_sync_pairing", as: String?.self)
        XCTAssertNil(cancelled)
        XCTAssertEqual(try vault.load(), state)
        do {
            let _: Bool = try await client.invoke("set_sync_enabled", arguments: Data("{\"enabled\":true}".utf8), as: Bool.self)
            XCTFail("The local binding must not open network sync")
        } catch NativeSyncError.operationFailed(_) { }
        let closed = await client.close()
        XCTAssertTrue(closed)
    }

    func testOrphanNativeSidecarWithoutKeyPreservesRecoveryBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sidecar = directory.appendingPathComponent("sync.db-wal")
        let bytes = Data("preserved recovery bytes".utf8)
        try bytes.write(to: sidecar)
        let vault = try EncryptedCompanionVault(fileURL: directory.appendingPathComponent("local-vault.bin"), keychainService: UUID().uuidString)
        XCTAssertThrowsError(try vault.withSyncKey { _, _ in () })
        XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sync.db").path))
    }

    func testManualSyncSnapshotUsesCanonicalIDsAndDatesWithoutPrivateNotes() throws {
        let entry = try ManualActivityEntry(
            id: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
            startedAt: Date(timeIntervalSince1970: 1_791_806_400), durationSeconds: 600,
            note: "PRIVATE NOTE MUST REMAIN LOCAL",
        )
        let data = try ManualSyncEntry.snapshot([entry])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(value["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), Set(["id", "timestamp", "duration_seconds"]))
        XCTAssertEqual(rows[0]["id"] as? String, "00112233-4455-6677-8899-aabbccddeeff")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: (rows[0]["timestamp"] as! String).replacingOccurrences(of: ".000", with: "")))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(entry.note))
        XCTAssertThrowsError(try ManualSyncEntry.snapshot([entry, entry]))
    }

    func testLegacyVaultDecodeRejectsInvalidDurationAndDuplicateIdentifiers() throws {
        let entry = try ManualActivityEntry(startedAt: .now, durationSeconds: 600, note: "Preserved private note")
        let original = try JSONEncoder().encode(CompanionVaultState(entries: [entry]))
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var rows = try XCTUnwrap(value["entries"] as? [[String: Any]])
        rows[0]["durationSeconds"] = Int.max
        value["entries"] = rows
        XCTAssertThrowsError(try JSONDecoder().decode(CompanionVaultState.self, from: JSONSerialization.data(withJSONObject: value)))
        rows[0]["durationSeconds"] = 600
        value["entries"] = [rows[0], rows[0]]
        XCTAssertThrowsError(try JSONDecoder().decode(CompanionVaultState.self, from: JSONSerialization.data(withJSONObject: value)))
        XCTAssertEqual(try JSONDecoder().decode(CompanionVaultState.self, from: original).entries, [entry])
    }
}
