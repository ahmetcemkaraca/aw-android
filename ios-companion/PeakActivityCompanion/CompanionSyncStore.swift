import Foundation
import SwiftUI

@MainActor
final class CompanionSyncStore: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var sharingEnabled = false
    @Published private(set) var projectionPending = false
    @Published private(set) var status = "Local sync controls are unavailable. Offline reports remain available."
    @Published private(set) var busy = false
    @Published private(set) var receivedReport: SyncedManualReport?
    @Published private(set) var pairingMessage = ""
    @Published private(set) var verificationCode = ""
    @Published private(set) var recoveryPhrase = ""
    @Published private(set) var recoveryFile: Data?
    @Published private(set) var devices: [SyncDeviceSummary] = []
    @Published private(set) var network: NativeNetworkStatus?
    @Published private(set) var destinations: [NativeSyncDestination] = []
    @Published private(set) var networkRunning = false
    @Published private(set) var stopping = false
    @Published private(set) var policyPreviewText = ""
    @Published private(set) var snapshotFile: Data?
    @Published private(set) var restorePreview: NativeRestorePreview?
    @Published private(set) var recoveryConfirmationNeeded = false
    @Published private(set) var entitlement: NativeEntitlementStatus?
    @Published private(set) var entitlementStatus = "Community local access. Paid sync access is unavailable."
    @Published var restorePhrase = "" { didSet { clearRestorePreview() } }
    private var policyBundle = Data()
    private var policyDiff = Data()
    private var restoreKit = Data()
    private var restoreSnapshot = Data()
    private var restoreArguments = Data()

    struct SyncDeviceSummary: Decodable, Identifiable, Sendable {
        let device_id: String
        let is_current_device: Bool
        let revoked_at: String?
        let needs_repair: Bool
        var id: String { device_id }
    }

    enum PairingStep: Equatable { case ready, response, offer, compare, confirmation, transfer, done }
    @Published private(set) var pairingStep = PairingStep.ready
    private var initiator = false
    private var peerConfirmation = Data()
    private var client: NativeSyncClient?
    private var localEntries: [ManualActivityEntry] = []
    private var revision: UInt64 = 0
    private var generation: UInt64 = 0
    private var projectionTask: Task<Void, Never>?
    private var reportRequest: UInt64 = 0
    private var entitlementRequest: UInt64 = 0
    private var networkRequest: UInt64 = 0
    private var restoreRevision: UInt64 = 0
    private var fileRequest: UInt64 = 0

    var pairingActive: Bool { pairingStep != .ready && pairingStep != .done }
    var recoveryActive: Bool { recoveryConfirmationNeeded || !recoveryPhrase.isEmpty }
    var sessionToken: UInt64 { generation }
    func beginFileOperation() -> UInt64 { fileRequest &+= 1; return fileRequest }
    func acceptsFileCallback(_ token: UInt64, operation: UInt64) -> Bool {
        available && generation == token && fileRequest == operation
    }
    var canPreviewRestore: Bool {
        available && !busy && !networkRunning && !sharingEnabled && !pairingActive && !recoveryActive
            && !restoreKit.isEmpty && !restoreSnapshot.isEmpty && !restorePhrase.isEmpty
    }

    func attach(_ client: NativeSyncClient) async {
        generation &+= 1
        let current = generation
        self.client = client
        do {
            let sharing = try await client.invoke("manual_report_sharing", as: Bool.self)
            guard generation == current else { return }
            sharingEnabled = sharing
            available = true
            status = "Network sync is Off. Reports can be prepared locally."
            if sharing { project() }
            await refreshDevices()
            await refreshNetwork()
        } catch {
            if generation == current { available = false; status = "The encrypted sync vault is unavailable. Local entries were preserved." }
        }
    }

    func detach() {
        if let client { Task { _ = await client.pause() } }
        generation &+= 1
        projectionTask?.cancel()
        projectionTask = nil
        client = nil
        available = false
        busy = false
        receivedReport = nil
        network = nil
        entitlement = nil
        entitlementStatus = "Community local access. Paid sync access is unavailable."
        destinations = []
        networkRunning = false
        stopping = false
        clearPolicyPreview()
        clearRestoreInputs()
        snapshotFile = nil
        recoveryConfirmationNeeded = false
        pairingStep = .ready
        pairingMessage = ""
        verificationCode = ""
        peerConfirmation.resetBytes(in: 0..<peerConfirmation.count)
        clearSensitiveDisplay()
        status = "Sync is paused while the app is inactive."
    }

    func setLocalEntries(_ entries: [ManualActivityEntry]) {
        localEntries = entries
        revision &+= 1
        receivedReport = nil
        clearRestorePreview()
        if sharingEnabled { projectionPending = true; project() }
    }

    func setSharing(_ enabled: Bool) async {
        guard let client, !busy, !enabled || !networkRunning else { return }
        busy = true
        let current = generation
        defer { if generation == current { busy = false } }
        do {
            if !enabled {
                networkRequest &+= 1
                stopping = true
                status = "Stopping after the current network request…"
                guard await client.pause() else { throw NativeSyncError.unavailable }
                guard generation == current else { return }
                stopping = false
            }
            let arguments = try JSONSerialization.data(withJSONObject: ["enabled": enabled, "userConfirmed": true])
            let saved = try await client.invoke("set_manual_report_sharing", arguments: arguments, as: Bool.self)
            guard generation == current else { return }
            sharingEnabled = saved
            status = saved ? "Manual dates and durations will be prepared. Notes and Screen Time selections stay local." : "Manual sharing is Off. Previously shared copies may remain on paired devices."
            if saved { projectionPending = true; project() }
            clearRestorePreview()
            await refreshNetwork()
        } catch { if generation == current { stopping = false; show(error) } }
    }

    private func project() {
        guard projectionTask == nil, sharingEnabled, let client else { return }
        let current = generation
        projectionTask = Task {
            defer { if generation == current { projectionTask = nil } }
            do {
                while !Task.isCancelled, generation == current, sharingEnabled {
                    let sourceRevision = revision
                    var data = try ManualSyncEntry.snapshot(localEntries)
                    defer { data.resetBytes(in: 0..<data.count) }
                    let receipt = try await client.invoke("reconcile_manual_entries", arguments: data, as: ManualProjectionReceipt.self)
                    guard !Task.isCancelled, generation == current else { return }
                    if revision == sourceRevision {
                        projectionPending = receipt.filtered > 0
                        status = receipt.filtered > 0 ? "Some entries remain local under your privacy rules." : "Manual report changes are ready locally."
                        return
                    }
                }
            } catch {
                if generation == current { projectionPending = true; status = "Manual changes are waiting to be prepared. Local entries were preserved." }
            }
        }
    }

    func retryProjection() { if sharingEnabled { projectionPending = true; project() } }

    func clearReceivedReport() { reportRequest &+= 1; receivedReport = nil }

    func readReceivedReport(on day: Date) async {
        guard let client else { return }
        let current = generation
        let sourceRevision = revision
        reportRequest &+= 1
        let requestID = reportRequest
        guard let interval = Calendar.current.dateInterval(of: .day, for: day) else { return }
        let formatter = ISO8601DateFormatter()
        do {
            let arguments = try JSONSerialization.data(withJSONObject: [
                "start": formatter.string(from: interval.start), "end": formatter.string(from: interval.end),
                "exclude_entry_ids": localEntries.map { $0.id.uuidString.lowercased() },
            ])
            let report = try await client.invoke("synced_manual_report", arguments: arguments, as: SyncedManualReport.self)
            if generation == current, revision == sourceRevision, reportRequest == requestID { receivedReport = report }
        } catch { if generation == current, reportRequest == requestID { receivedReport = nil; show(error) } }
    }

    private func object(_ text: String) throws -> [String: Any] {
        guard text.utf8.count <= 16 * 1_048_576,
              let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw NativeSyncError.invalidRequest
        }
        return value
    }

    private func run(_ command: String, arguments: [String: Any] = [:]) async throws -> Data {
        guard let client else { throw NativeSyncError.unavailable }
        let current = generation
        var request = try JSONSerialization.data(withJSONObject: arguments)
        defer { request.resetBytes(in: 0..<request.count) }
        var result = try await client.invokeJSON(command, arguments: request)
        guard generation == current, available else {
            result.resetBytes(in: 0..<result.count)
            throw CancellationError()
        }
        return result
    }

    func showDeviceCode() async {
        await operation { pairingMessage = String(decoding: try await run("create_local_sync_identity"), as: UTF8.self) }
    }

    func startPairing(_ recipient: String) async {
        guard !recoveryActive else { status = "Save or cancel recovery setup before pairing."; return }
        await operation {
            let message = try await run("create_sync_pairing", arguments: ["recipient": try object(recipient)])
            pairingMessage = String(decoding: message, as: UTF8.self)
            initiator = true; pairingStep = .response
        }
    }

    func respondToInvitation(_ invitation: String) async {
        guard !recoveryActive else { status = "Save or cancel recovery setup before pairing."; return }
        await operation {
            let message = try await run("respond_sync_pairing", arguments: ["invitation": try object(invitation)])
            pairingMessage = String(decoding: message, as: UTF8.self)
            initiator = false; pairingStep = .offer
        }
    }

    func receivePairingMessage(_ text: String) async {
        await operation {
            switch pairingStep {
            case .response:
                let data = try await run("complete_sync_pairing", arguments: ["response": try object(text)])
                let value = try object(String(decoding: data, as: UTF8.self))
                guard let code = value["verification_code"] as? String, let offer = value["offer"] else { throw NativeSyncError.invalidResponse }
                verificationCode = code
                pairingMessage = String(decoding: try JSONSerialization.data(withJSONObject: offer, options: .sortedKeys), as: UTF8.self)
                pairingStep = .compare
            case .offer:
                let data = try await run("prepare_sync_pairing", arguments: ["offer": try object(text)])
                verificationCode = try JSONDecoder().decode(String.self, from: data)
                pairingStep = .compare
            case .confirmation:
                let confirmation = try object(text)
                if initiator {
                    pairingMessage = String(decoding: try await run("create_sync_key_transfer", arguments: ["peerConfirmation": confirmation]), as: UTF8.self)
                    pairingStep = .done
                    await refreshDevices()
                } else {
                    peerConfirmation = try JSONSerialization.data(withJSONObject: confirmation)
                    pairingStep = .transfer
                }
            case .transfer:
                _ = try await run("accept_sync_key_transfer", arguments: ["peerConfirmation": try object(String(decoding: peerConfirmation, as: UTF8.self)), "transfer": try object(text)])
                peerConfirmation.resetBytes(in: 0..<peerConfirmation.count)
                pairingStep = .done
                await refreshDevices()
            default: throw NativeSyncError.invalidRequest
            }
        }
    }

    func confirmPairingCode() async {
        await operation {
            pairingMessage = String(decoding: try await run("confirm_sync_pairing", arguments: ["displayedCode": verificationCode, "userConfirmed": true]), as: UTF8.self)
            pairingStep = .confirmation
        }
    }

    func cancelPairing() async {
        await operation { _ = try await run("cancel_sync_pairing"); pairingStep = .ready; pairingMessage = ""; verificationCode = ""; peerConfirmation.resetBytes(in: 0..<peerConfirmation.count) }
    }

    func makeRecoveryKit() async {
        guard !pairingActive else { status = "Finish or cancel device pairing before recovery setup."; return }
        await operation {
            var data = try await run("create_sync_recovery_kit")
            defer { data.resetBytes(in: 0..<data.count) }
            let value = try object(String(decoding: data, as: UTF8.self))
            guard let phrase = value["recovery_phrase"] as? String, let kit = value["kit"] else { throw NativeSyncError.invalidResponse }
            recoveryPhrase = phrase
            recoveryFile = try JSONSerialization.data(withJSONObject: kit, options: .sortedKeys)
            recoveryConfirmationNeeded = true
        }
    }

    func confirmRecoverySaved() async {
        await operation { _ = try await run("confirm_sync_recovery_saved", arguments: ["userConfirmed": true]); recoveryConfirmationNeeded = false; clearSensitiveDisplay() }
    }

    func cancelRecovery() async {
        await operation { _ = try await run("cancel_sync_recovery_kit"); recoveryConfirmationNeeded = false; clearSensitiveDisplay() }
    }

    func recoveryExportFailed() {
        status = "The recovery file could not be saved. Try again before confirming recovery setup."
    }

    func refreshDevices() async {
        guard let client else { return }
        let current = generation
        do {
            let value = try await client.invoke("list_sync_devices", as: [SyncDeviceSummary].self)
            if generation == current { devices = value }
        } catch { if generation == current { show(error) } }
    }

    func revokeDevice(_ id: String) async {
        await operation { _ = try await run("revoke_sync_device", arguments: ["deviceId": id]); await refreshDevices() }
    }

    func refreshNetwork() async {
        guard let client else { return }
        let current = generation
        do {
            let state = try await client.invoke("sync_network_status", as: NativeNetworkStatus.self)
            guard generation == current else { return }
            network = state
            if state.egress.outbound_enabled {
                let options = try await client.invoke("sync_signed_destinations", as: [NativeSyncDestination].self)
                if generation == current { destinations = options }
            } else { destinations = [] }
        } catch { if generation == current { network = nil; destinations = []; show(error) } }
        if generation == current { await refreshEntitlement() }
    }

    func refreshEntitlement() async {
        guard let client else { return }
        let current = generation
        entitlementRequest &+= 1
        let request = entitlementRequest
        do {
            let value = try await client.invoke("entitlement_status", as: NativeEntitlementStatus?.self)
            guard generation == current, entitlementRequest == request else { return }
            entitlement = value
            entitlementStatus = value.map { "Plan: \($0.plan_id) · \($0.access)" }
                ?? "Community local access. Paid sync access is unavailable."
        } catch {
            if generation == current, entitlementRequest == request { entitlement = nil; entitlementStatus = "Paid sync access is unavailable. Local features remain available." }
        }
    }

    func importEntitlement(_ data: Data) async {
        await operation {
            guard !data.isEmpty, data.count <= EntitlementStore.maximumProofBytes,
                  let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeSyncError.invalidRequest
            }
            let current = generation
            entitlementRequest &+= 1
            var arguments = try JSONSerialization.data(withJSONObject: ["proof": document])
            defer { arguments.resetBytes(in: 0..<arguments.count) }
            do {
                guard let client else { throw NativeSyncError.unavailable }
                _ = try await client.invoke("import_entitlement", arguments: arguments, as: NativeEntitlementStatus.self)
                guard generation == current else { return }
                await refreshEntitlement()
                if generation == current { status = "The signed entitlement was verified and stored separately from activity." }
            } catch {
                if generation == current { await refreshEntitlement() }
                throw error
            }
        }
    }

    func previewPolicy(_ data: Data) async {
        await operation {
            clearPolicyPreview()
            let bundle = try object(String(decoding: data, as: UTF8.self))
            var preview = try await run("preview_sync_policy", arguments: ["bundle": bundle])
            defer { preview.resetBytes(in: 0..<preview.count) }
            let changes = try object(String(decoding: preview, as: UTF8.self))
            policyBundle = data
            policyDiff = preview
            policyPreviewText = String(decoding: try JSONSerialization.data(withJSONObject: changes, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
            status = "Review the signed destinations, allowed fields and retention changes before accepting."
        }
    }

    func acceptPolicy() async {
        await operation {
            guard !policyBundle.isEmpty, !policyDiff.isEmpty else { throw NativeSyncError.invalidRequest }
            guard let client else { throw NativeSyncError.unavailable }
            let current = generation
            guard await client.pause() else { throw NativeSyncError.unavailable }
            guard generation == current else { return }
            _ = try await run("accept_sync_policy", arguments: [
                "bundle": try object(String(decoding: policyBundle, as: UTF8.self)),
                "expected_diff": try object(String(decoding: policyDiff, as: UTF8.self)), "userConfirmed": true,
            ])
            clearPolicyPreview()
            status = "Signed policy accepted. Network sync remains Off until you enable it."
            await refreshNetwork()
        }
    }

    func setKillSwitch(_ enabled: Bool) async {
        guard available, !busy, !stopping, enabled || !networkRunning else { return }
        if enabled { await stopNetwork() }
        guard available, !busy else { return }
        let current = generation
        busy = true
        defer { if generation == current { busy = false } }
        do {
            _ = try await run("set_egress_kill_switch", arguments: ["enabled": enabled])
            await refreshNetwork()
            guard generation == current else { return }
            status = enabled ? "All outbound requests are blocked." : "Outbound block removed. Sync still requires a verified service and your approval."
        } catch { if generation == current { show(error) } }
    }

    func enableNetwork(_ destinationID: String) async {
        await operation {
            let current = generation
            guard let choice = destinations.first(where: { $0.id == destinationID }) else { throw NativeSyncError.invalidRequest }
            _ = try await run("set_sync_enabled", arguments: ["enabled": true, "userConfirmed": true,
                "destination_id": choice.destination_id, "purpose_id": choice.purpose_id])
            await refreshNetwork()
            guard generation == current else { return }
            status = network?.sync.preparing == true ? "Preparing a bounded part of the encrypted baseline. Continue preparation to finish." : "Encrypted sync is enabled. Run a cycle while the app is open."
        }
    }

    func stopNetwork() async {
        guard let client, !stopping else { return }
        let current = generation
        networkRequest &+= 1
        stopping = true
        status = "Stopping after the current network request…"
        let paused = await client.pause()
        guard generation == current else { return }
        stopping = false
        await refreshNetwork()
        guard generation == current else { return }
        status = paused ? "Network sync is Off. Prepared local data and keys are preserved." : "Sync could not be stopped. Keep the app open and try again."
    }

    func runNetwork() async {
        guard let client, available, !busy, !networkRunning, !stopping, network?.sync.enabled == true else { return }
        networkRunning = true
        let current = generation
        let request = networkRequest
        status = "Syncing encrypted activity while the app is open…"
        defer { if generation == current { networkRunning = false } }
        do {
            let result = try await client.runSyncOnce()
            guard generation == current else { return }
            if networkRequest == request {
                status = result.success ? "Encrypted sync cycle completed." : (result.retryable ? "The service is unavailable. Local changes are queued; retry when ready." : (result.error ?? "The sync request was refused."))
            }
        } catch { if generation == current, networkRequest == request { show(error) } }
        if generation == current { await refreshNetwork(); if generation == current { clearReceivedReport() } }
    }

    func exportSnapshot() async {
        snapshotFile = nil
        await operation {
            _ = try await run("create_current_sync_snapshot")
            snapshotFile = try await run("export_sync_snapshot")
            status = "The encrypted snapshot is ready to save. Keep its recovery file and phrase separately."
        }
    }

    func importRecoveryKit(_ data: Data) throws {
        guard available, !busy, !networkRunning else { throw NativeSyncError.invalidRequest }
        _ = try object(String(decoding: data, as: UTF8.self))
        clearRestorePreview()
        restoreKit.resetBytes(in: 0..<restoreKit.count)
        restoreKit = data
        status = "Recovery file selected locally. Add its encrypted snapshot and phrase, then review the restore."
    }

    func importSnapshot(_ data: Data) throws {
        guard available, !busy, !networkRunning else { throw NativeSyncError.invalidRequest }
        _ = try object(String(decoding: data, as: UTF8.self))
        clearRestorePreview()
        restoreSnapshot.resetBytes(in: 0..<restoreSnapshot.count)
        restoreSnapshot = data
        status = "Encrypted snapshot selected locally. Review the restore before accepting."
    }

    func previewRestore() async {
        guard canPreviewRestore else { return }
        await operation {
            clearRestorePreview()
            var arguments = try JSONSerialization.data(withJSONObject: [
                "kit": try object(String(decoding: restoreKit, as: UTF8.self)), "recoveryPhrase": restorePhrase,
                "snapshot": try object(String(decoding: restoreSnapshot, as: UTF8.self)),
            ])
            defer { arguments.resetBytes(in: 0..<arguments.count) }
            guard let client else { throw NativeSyncError.unavailable }
            let current = generation
            let inputRevision = restoreRevision
            let preview = try await client.invoke("preview_sync_recovery_restore", arguments: arguments, as: NativeRestorePreview.self)
            guard generation == current, restoreRevision == inputRevision else { return }
            restoreArguments = arguments
            restorePreview = preview
        }
    }

    func acceptRestore() async {
        await operation {
            guard restorePreview != nil, !restoreArguments.isEmpty, !sharingEnabled else { throw NativeSyncError.invalidRequest }
            var arguments = try object(String(decoding: restoreArguments, as: UTF8.self))
            arguments["userAccepted"] = true
            _ = try await run("restore_sync_recovery_kit", arguments: arguments)
            clearRestoreInputs()
            recoveryConfirmationNeeded = true
            status = "Encrypted activity restored. Local entries and private notes were preserved. Confirm that the recovery materials are saved before enabling sync."
            await refreshDevices()
            await refreshNetwork()
        }
    }

    func fileOperationFailed(_ error: Error) { show(error) }

    func cancelRestore() { if !busy { clearRestoreInputs() } }

    private func clearPolicyPreview() {
        policyBundle.resetBytes(in: 0..<policyBundle.count)
        policyDiff.resetBytes(in: 0..<policyDiff.count)
        policyBundle = Data(); policyDiff = Data(); policyPreviewText = ""
    }

    private func clearRestorePreview() {
        restoreRevision &+= 1
        restoreArguments.resetBytes(in: 0..<restoreArguments.count)
        restoreArguments = Data(); restorePreview = nil
    }

    private func clearRestoreInputs() {
        clearRestorePreview()
        restoreKit.resetBytes(in: 0..<restoreKit.count)
        restoreSnapshot.resetBytes(in: 0..<restoreSnapshot.count)
        restoreKit = Data(); restoreSnapshot = Data(); restorePhrase = ""
    }

    private func operation(_ action: () async throws -> Void) async {
        guard available, !busy, !networkRunning, !stopping else { return }
        busy = true
        let current = generation
        defer { if generation == current { busy = false } }
        do { try await action() } catch { if generation == current { show(error) } }
    }

    private func clearSensitiveDisplay() {
        recoveryPhrase = ""
        let size = recoveryFile?.count ?? 0
        recoveryFile?.resetBytes(in: 0..<size)
        recoveryFile = nil
    }

    private func show(_ error: Error) {
        if case NativeSyncError.operationFailed(let message) = error { status = message }
        else { status = "The sync operation could not be completed. Local entries were preserved." }
    }
}
