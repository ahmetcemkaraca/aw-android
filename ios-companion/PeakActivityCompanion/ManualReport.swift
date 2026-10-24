import Foundation
import FamilyControls

enum ManualEntryValidationError: Error {
    case invalidDuration
    case noteTooLong
    case invalidTimestamp
    case invalidSnapshot
}

struct ManualActivityEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: Int
    let note: String

    init(id: UUID = UUID(), startedAt: Date, durationSeconds: Int, note: String) throws {
        guard (1...86_400).contains(durationSeconds) else {
            throw ManualEntryValidationError.invalidDuration
        }
        guard note.count <= 500 else { throw ManualEntryValidationError.noteTooLong }
        guard startedAt.timeIntervalSince1970.isFinite else { throw ManualEntryValidationError.invalidTimestamp }
        self.id = id
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case id, startedAt, durationSeconds, note }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), startedAt: values.decode(Date.self, forKey: .startedAt),
                      durationSeconds: values.decode(Int.self, forKey: .durationSeconds), note: values.decode(String.self, forKey: .note))
    }
}

struct CompanionVaultState: Codable, Equatable {
    var entries: [ManualActivityEntry] = []
    var familyActivitySelection: FamilyActivitySelection?

    init(entries: [ManualActivityEntry] = [], familyActivitySelection: FamilyActivitySelection? = nil) {
        self.entries = entries
        self.familyActivitySelection = familyActivitySelection
    }

    private enum CodingKeys: String, CodingKey { case entries, familyActivitySelection }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try values.decode([ManualActivityEntry].self, forKey: .entries)
        guard entries.count <= 10_000, Set(entries.map(\.id)).count == entries.count else {
            throw ManualEntryValidationError.invalidSnapshot
        }
        self.entries = entries
        familyActivitySelection = try values.decodeIfPresent(FamilyActivitySelection.self, forKey: .familyActivitySelection)
    }
}

struct LocalReportSummary: Equatable {
    let entryCount: Int
    let totalDurationSeconds: Int

    static func make(entries: [ManualActivityEntry], on date: Date, calendar: Calendar = .current) -> Self {
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            return Self(entryCount: 0, totalDurationSeconds: 0)
        }
        let dailyEntries = entries.filter { interval.contains($0.startedAt) }
        return Self(
            entryCount: dailyEntries.count,
            totalDurationSeconds: dailyEntries.reduce(0) { $0 + $1.durationSeconds },
        )
    }
}

struct SyncedManualReport: Decodable, Sendable {
    let entry_count: Int
    let total_duration_seconds: Int
}

struct ManualProjectionReceipt: Decodable, Sendable {
    let inserted: Int
    let corrected: Int
    let deleted: Int
    let filtered: Int
}

struct ManualSyncEntry: Encodable {
    let id: String
    let timestamp: String
    let duration_seconds: Int

    static func snapshot(_ entries: [ManualActivityEntry]) throws -> Data {
        guard entries.count <= 10_000, Set(entries.map(\.id)).count == entries.count else {
            throw NativeSyncError.invalidRequest
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let values = try entries.map { entry -> ManualSyncEntry in
            guard (1...86_400).contains(entry.durationSeconds), entry.startedAt.timeIntervalSince1970.isFinite else {
                throw NativeSyncError.invalidRequest
            }
            return ManualSyncEntry(id: entry.id.uuidString.lowercased(), timestamp: formatter.string(from: entry.startedAt), duration_seconds: entry.durationSeconds)
        }
        struct Snapshot: Encodable { let entries: [ManualSyncEntry] }
        return try JSONEncoder().encode(Snapshot(entries: values))
    }
}
