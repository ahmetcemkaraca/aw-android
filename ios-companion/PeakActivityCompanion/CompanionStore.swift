import FamilyControls
import Foundation
import SwiftUI

@MainActor
final class CompanionStore: ObservableObject {
    @Published private(set) var entries: [ManualActivityEntry] = []
    @Published var familySelection = FamilyActivitySelection()
    @Published var familyPickerPresented = false
    @Published private(set) var screenTimeStatus = "Screen Time is not configured. Manual reports remain available."
    @Published private(set) var storageStatus = ""
    @Published private(set) var canWrite = true

    private let vault: EncryptedCompanionVault?
    private var state = CompanionVaultState()

    init() {
        vault = try? EncryptedCompanionVault()
        if vault == nil {
            canWrite = false
            storageStatus = "The local encrypted vault is unavailable. Existing data was preserved."
        } else {
            load()
        }
    }

    var syncStatus: String {
        "E2EE sync is unavailable in this iOS prototype. No network request is made."
    }

    var aiStatus: String { "AI is Off. This companion has no model or endpoint client." }

    func load() {
        guard let vault else { return }
        do {
            state = try vault.load()
            entries = state.entries.sorted { $0.startedAt > $1.startedAt }
            familySelection = state.familyActivitySelection ?? FamilyActivitySelection()
            storageStatus = "Manual entries and selection tokens are encrypted on this device."
            if state.familyActivitySelection != nil {
                screenTimeStatus = AuthorizationCenter.shared.authorizationStatus == .approved
                    ? "An opaque Screen Time selection is stored on this device."
                    : "The stored selection needs reauthorization. No Screen Time data is being read."
            }
            canWrite = true
        } catch {
            canWrite = false
            storageStatus = "The encrypted local vault cannot be opened. Existing data was preserved."
        }
    }

    func beginFamilyControlFlow() {
        guard canWrite else {
            screenTimeStatus = "The encrypted local vault is unavailable; Screen Time selection was not requested."
            return
        }
        Task {
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                guard AuthorizationCenter.shared.authorizationStatus == .approved else {
                    screenTimeStatus = "Screen Time authorization was not approved. Manual reports remain available."
                    return
                }
                screenTimeStatus = "Choose Screen Time items in Apple's picker. PeakActivity stores only opaque selection tokens."
                familyPickerPresented = true
            } catch {
                screenTimeStatus = "Screen Time is unavailable on this device or entitlement. Manual reports remain available."
            }
        }
    }

    func persistFamilySelection(_ selection: FamilyActivitySelection) {
        familySelection = selection
        var next = state
        next.familyActivitySelection = selection
        _ = persist(next)
    }

    @discardableResult
    func addManualEntry(durationMinutes: Int, note: String) -> Bool {
        guard canWrite, entries.count < 10_000, (1...1_440).contains(durationMinutes) else { return false }
        guard let entry = try? ManualActivityEntry(
            startedAt: Date(), durationSeconds: durationMinutes * 60, note: note,
        ) else { return false }
        var next = state
        next.entries.append(entry)
        return persist(next)
    }

    @discardableResult
    func deleteManualEntry(_ id: UUID) -> Bool {
        guard canWrite else { return false }
        var next = state
        next.entries.removeAll { $0.id == id }
        return persist(next)
    }

    func report(for day: Date = Date(), calendar: Calendar = .current) -> LocalReportSummary {
        LocalReportSummary.make(entries: entries, on: day, calendar: calendar)
    }

    private func persist(_ next: CompanionVaultState) -> Bool {
        guard canWrite, let vault else { return false }
        do {
            try vault.save(next)
            state = next
            entries = next.entries.sorted { $0.startedAt > $1.startedAt }
            storageStatus = "Manual entries and selection tokens are encrypted on this device."
            return true
        } catch {
            storageStatus = "The local encrypted vault could not be saved. Existing data was preserved."
            return false
        }
    }
}
