import CryptoKit
import FamilyControls
import Foundation
import XCTest
@testable import PeakActivityCompanion

final class CompanionContractTests: XCTestCase {
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
}
