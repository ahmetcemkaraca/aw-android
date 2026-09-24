import Foundation
import FamilyControls

enum ManualEntryValidationError: Error {
    case invalidDuration
    case noteTooLong
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
        self.id = id
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.note = note
    }
}

struct CompanionVaultState: Codable, Equatable {
    var entries: [ManualActivityEntry] = []
    var familyActivitySelection: FamilyActivitySelection?
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
