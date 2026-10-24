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
    @Published private var nativeSync: NativeSyncClient?
    private var syncOpenTask: Task<Void, Never>?
    private var syncCloseTask: Task<Bool, Never>?
    private var closingSyncClient: NativeSyncClient?
    private var syncGeneration: UInt64 = 0
    let sync = CompanionSyncStore()

    init() {
        vault = try? EncryptedCompanionVault()
        if vault == nil {
            canWrite = false
            storageStatus = "The local encrypted vault is unavailable. Existing data was preserved."
        } else {
            load()
        }
    }

    var aiStatus: String { "AI is Off. AI requests are unavailable in this companion." }

    func load() {
        guard let vault else { return }
        do {
            state = try vault.load()
            entries = state.entries.sorted { $0.startedAt > $1.startedAt }
            sync.setLocalEntries(state.entries)
            familySelection = state.familyActivitySelection ?? FamilyActivitySelection()
            storageStatus = "Manual entries and selection tokens are encrypted on this device."
            if state.familyActivitySelection != nil {
                screenTimeStatus = AuthorizationCenter.shared.authorizationStatus == .approved
                    ? "An opaque Screen Time selection is stored on this device."
                    : "The stored selection needs reauthorization. No Screen Time data is being read."
            }
            canWrite = true
            openLocalSync()
        } catch {
            suspendLocalSync()
            canWrite = false
            storageStatus = "The encrypted local vault cannot be opened. Existing data was preserved."
        }
    }

    func suspendLocalSync() {
        sync.detach()
        syncGeneration &+= 1
        let opening = syncOpenTask
        opening?.cancel()
        syncOpenTask = nil
        let client = nativeSync
        nativeSync = nil
        if opening != nil || client != nil {
            let previous = syncCloseTask
            syncCloseTask = Task {
                if let previous { _ = await previous.value }
                // Detached vault opening cannot be cancelled; wait for its stale-handle cleanup.
                if let opening { await opening.value }
                if let client {
                    return await closeSyncClient(client)
                }
                return true
            }
        }
    }

    private func openLocalSync() {
        guard nativeSync == nil, syncOpenTask == nil, let vault else { return }
        let generation = syncGeneration
        syncOpenTask = Task {
            defer { if generation == syncGeneration { syncOpenTask = nil } }
            do {
                if let closing = syncCloseTask {
                    _ = await closing.value
                    guard !Task.isCancelled, generation == syncGeneration else { return }
                    syncCloseTask = nil
                }
                if let closingSyncClient {
                    guard await closeSyncClient(closingSyncClient) else { return }
                    guard !Task.isCancelled, generation == syncGeneration else { return }
                }
                let client = try await NativeSyncClient.open(vault: vault)
                guard !Task.isCancelled, generation == syncGeneration else { _ = await closeSyncClient(client); return }
                do {
                    guard await client.pause() else { _ = await closeSyncClient(client); return }
                    let enabled = try await client.invoke("sync_enabled", as: Bool.self)
                    guard !enabled, !Task.isCancelled, generation == syncGeneration else { _ = await closeSyncClient(client); return }
                    nativeSync = client
                    await sync.attach(client)
                } catch { _ = await closeSyncClient(client) }
            } catch {
                if generation == syncGeneration { nativeSync = nil }
            }
        }
    }

    private func closeSyncClient(_ client: NativeSyncClient) async -> Bool {
        closingSyncClient = client
        _ = await client.pause()
        let closed = await client.close()
        if closed, closingSyncClient === client { closingSyncClient = nil }
        return closed
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
            sync.setLocalEntries(next.entries)
            storageStatus = "Manual entries and selection tokens are encrypted on this device."
            return true
        } catch {
            storageStatus = "The local encrypted vault could not be saved. Existing data was preserved."
            return false
        }
    }
}
