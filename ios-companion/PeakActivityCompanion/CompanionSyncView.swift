import SwiftUI
import UniformTypeIdentifiers

struct SyncFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let value = configuration.file.regularFileContents, value.count <= 16 * 1_048_576 else {
            throw NativeSyncError.invalidRequest
        }
        data = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct CompanionSyncView: View {
    @ObservedObject var store: CompanionSyncStore
    @State private var confirmSharing = false
    @State private var confirmCode = false
    @State private var revokedDevice: String?
    @State private var message = ""
    @State private var selectedDay = Date()
    @State private var exportFile = false
    @State private var exportDocument: SyncFile?
    @State private var exportFilename = "PeakActivity-recovery-kit"
    @State private var selectedDestination = ""
    @State private var confirmOutbound = false
    @State private var confirmNetwork = false
    @State private var confirmPolicy = false
    @State private var confirmRestore = false
    @State private var importFile = false
    private enum ImportKind { case policy, kit, snapshot, entitlement }
    @State private var importKind = ImportKind.policy
    @State private var fileSession: UInt64 = 0
    @State private var fileOperation: UInt64 = 0

    var body: some View {
        Form {
            Section("Plan and sync access") {
                Text(store.entitlementStatus).accessibilityLabel("Plan status: \(store.entitlementStatus)")
                Text(store.entitlement?.sync_allowed == true
                     ? "Encrypted network sync access is available. Access is verified for every request."
                     : "Encrypted network sync access is unavailable.").font(.footnote)
                Button("Import signed entitlement") { startImport(.entitlement) }
                    .disabled(!store.available || store.busy || store.networkRunning)
                Text("Local history, export, decrypt, delete and pause remain available. Billing proof is stored separately from activity.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            networkSection
            Section("Manual reports") {
                Toggle("Prepare manual reports for sync", isOn: Binding(
                    get: { store.sharingEnabled },
                    set: { enabled in
                        if enabled { confirmSharing = true }
                        else { Task { await store.setSharing(false) } }
                    }
                ))
                .disabled(!store.available || store.busy)
                Text("Only dates and durations are prepared. Private notes and Screen Time selections stay on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(store.status).accessibilityLabel("Sync status: \(store.status)")
                if store.projectionPending {
                    Text("Local manual changes are waiting to be prepared.").font(.footnote)
                    Button("Retry preparation") { store.retryProjection() }.disabled(!store.available || store.busy)
                }
            }

            Section("Received manual report") {
                DatePicker("Report day", selection: $selectedDay, displayedComponents: .date)
                    .onChange(of: selectedDay) { _ in store.clearReceivedReport() }
                Button("Read received report") { Task { await store.readReceivedReport(on: selectedDay) } }
                    .disabled(!store.available)
                if let report = store.receivedReport {
                    Text("\(report.entry_count) entries · \(report.total_duration_seconds / 60) minutes")
                }
                Text("Includes manual reports already in the encrypted vault from paired devices. This device's local entries are shown on Home.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Pair another device") {
                Button("Show this device's code") { Task { await store.showDeviceCode() } }
                if !store.pairingMessage.isEmpty {
                    Text("Send this message to your other PeakActivity device.").font(.footnote)
                    ShareLink("Share pairing message", item: store.pairingMessage)
                }
                TextEditor(text: $message)
                    .frame(minHeight: 100)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Pairing message from your other device")
                if store.pairingStep == .ready {
                    Button("Start with the other device's code") { Task { await store.startPairing(message); message = "" } }
                    Button("Respond to an invitation") { Task { await store.respondToInvitation(message); message = "" } }
                } else if store.pairingStep == .compare {
                    Text("Compare this code on both devices: \(store.verificationCode)")
                        .font(.headline).textSelection(.enabled)
                    Button("Codes match on both devices") { confirmCode = true }
                } else if store.pairingStep == .done {
                    Text("Pairing completed. Share the final encrypted message if this device started the pairing.")
                } else {
                    Text(pairingInstruction).font(.footnote)
                    Button("Use received message") { Task { await store.receivePairingMessage(message); message = "" } }
                }
                Button("Cancel pairing", role: .cancel) { Task { await store.cancelPairing(); message = "" } }
            }
            .disabled(!store.available || store.busy || store.networkRunning || store.recoveryActive)

            Section("Recovery") {
                Button("Create recovery kit") { Task { await store.makeRecoveryKit() } }
                    .disabled(!store.available || store.busy || store.networkRunning || store.pairingActive || store.recoveryActive)
                if !store.recoveryPhrase.isEmpty {
                    Text("Save this phrase offline. The recovery file alone cannot unlock your data.")
                    Text(store.recoveryPhrase).textSelection(.enabled).privacySensitive()
                    Button("Save encrypted recovery file") { if let data = store.recoveryFile { export(data, name: "PeakActivity-recovery-kit") } }
                }
                if store.recoveryConfirmationNeeded {
                    Button("I saved the recovery phrase and file") { Task { await store.confirmRecoverySaved() } }
                        .disabled(store.busy)
                    Button("Cancel recovery confirmation", role: .cancel) { Task { await store.cancelRecovery() } }
                        .disabled(store.busy)
                }
            }

            snapshotSection

            Section("Paired devices") {
                ForEach(store.devices) { device in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.is_current_device ? "This device" : "Paired device · \(device.device_id.suffix(6))")
                        if device.revoked_at != nil { Text("Access revoked").font(.footnote) }
                        else if device.needs_repair { Text("Pair again to restore access").font(.footnote) }
                        if !device.is_current_device, device.revoked_at == nil {
                            Button("Revoke device access", role: .destructive) { revokedDevice = device.id }
                                .disabled(store.busy)
                        }
                    }
                }
                Button("Refresh devices") { Task { await store.refreshDevices() } }.disabled(!store.available)
            }

            Section("Background behavior") {
                Text("Pairing and report preparation are local. Network sync requires a configured service and runs only after your request while this app is open.")
            }
        }
        .navigationTitle("Sync and devices")
        .confirmationDialog("Share manual dates and durations?", isPresented: $confirmSharing, titleVisibility: .visible) {
            Button("Prepare reports") { Task { await store.setSharing(true) } }
            Button("Keep local", role: .cancel) { }
        } message: { Text("Private notes and Screen Time selections stay local. No network request starts from this choice.") }
        .confirmationDialog("Do both devices show the same code?", isPresented: $confirmCode, titleVisibility: .visible) {
            Button("Confirm matching codes") { Task { await store.confirmPairingCode() } }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Revoke this device's access?", isPresented: Binding(get: { revokedDevice != nil }, set: { if !$0 { revokedDevice = nil } }), titleVisibility: .visible) {
            Button("Revoke access", role: .destructive) { if let id = revokedDevice { Task { await store.revokeDevice(id) } }; revokedDevice = nil }
            Button("Cancel", role: .cancel) { revokedDevice = nil }
        } message: { Text("Other devices will need current keys. Save a new recovery kit after the key change.") }
        .confirmationDialog("Allow outbound requests under the signed policy?", isPresented: $confirmOutbound, titleVisibility: .visible) {
            Button("Allow outbound requests") { Task { await store.setKillSwitch(false) } }
            Button("Keep blocked", role: .cancel) { }
        }
        .confirmationDialog("Enable encrypted sync to this destination?", isPresented: $confirmNetwork, titleVisibility: .visible) {
            Button("Enable encrypted sync") { Task { await store.enableNetwork(selectedDestination) } }
            Button("Keep Off", role: .cancel) { }
        } message: { Text("Prepared activity is encrypted before sending. This choice does not start a network request; use Run sync when ready.") }
        .confirmationDialog("Accept these signed policy changes?", isPresented: $confirmPolicy, titleVisibility: .visible) {
            Button("Accept reviewed changes") { Task { await store.acceptPolicy() } }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Restore this encrypted snapshot?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore reviewed snapshot") { Task { await store.acceptRestore() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Restores activity and sync continuity into a clean sync vault. Your offline entries, private notes and Screen Time selection stay on this device. Network sync remains Off.") }
        .fileExporter(isPresented: $exportFile, document: exportDocument, contentType: .json, defaultFilename: exportFilename) { [fileSession, fileOperation] result in
            guard store.acceptsFileCallback(fileSession, operation: fileOperation) else { return }
            if case .failure(let error) = result { store.fileOperationFailed(error) }
            exportDocument = nil
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.json]) { [fileSession, fileOperation, importKind] result in
            let kind = importKind
            let session = fileSession
            Task {
                do {
                    let url = try result.get()
                    var data = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        let limit = kind == .entitlement ? EntitlementStore.maximumProofBytes : 16 * 1_048_576
                        guard values.isRegularFile == true, let size = values.fileSize, size <= limit else { throw NativeSyncError.invalidRequest }
                        let file = try FileHandle(forReadingFrom: url)
                        defer { try? file.close() }
                        let bytes = try file.read(upToCount: limit + 1) ?? Data()
                        guard bytes.count <= limit else { throw NativeSyncError.invalidRequest }
                        return bytes
                    }.value
                    defer { data.resetBytes(in: 0..<data.count) }
                    guard store.acceptsFileCallback(session, operation: fileOperation) else { return }
                    switch kind {
                    case .policy: await store.previewPolicy(data)
                    case .kit: try store.importRecoveryKit(data)
                    case .snapshot: try store.importSnapshot(data)
                    case .entitlement: await store.importEntitlement(data)
                    }
                } catch { if store.acceptsFileCallback(session, operation: fileOperation) { store.fileOperationFailed(error) } }
            }
        }
        .onChange(of: store.available) { available in
            if !available { exportDocument = nil; exportFile = false; importFile = false }
        }
    }

    private var networkSection: some View {
        Section("Network sync") {
            Toggle("Block all outbound requests", isOn: Binding(
                get: { store.network?.egress.kill_switch_enabled ?? true },
                set: { blocked in if blocked { Task { await store.setKillSwitch(true) } } else { confirmOutbound = true } }
            ))
            .disabled(!store.available || store.busy || store.stopping)
            if store.network?.egress.trusted_policy_keys == 0 {
                Text("This build has no approved service keys. Network sync is unavailable.").font(.footnote)
            }
            Button("Import signed service policy") { startImport(.policy) }
                .disabled(!store.available || store.busy || store.networkRunning)
            if !store.policyPreviewText.isEmpty {
                DisclosureGroup("Review destinations, fields and retention changes") {
                    Text(store.policyPreviewText).font(.footnote).textSelection(.enabled)
                }
                Button("Accept policy changes") { confirmPolicy = true }.disabled(store.busy)
            }
            Picker("Signed destination", selection: $selectedDestination) {
                Text("Choose a destination").tag("")
                ForEach(store.destinations) { destination in Text(destination.label).tag(destination.id) }
            }
            if let selected = store.destinations.first(where: { $0.id == selectedDestination }) {
                Text(selected.retention_disclosure).font(.footnote)
                Text("Allowed fields: \(selected.allowed_fields.joined(separator: ", "))").font(.footnote).foregroundStyle(.secondary)
            }
            if let baseline = store.network?.sync.baseline, !baseline.complete {
                Text("Preparing encrypted baseline: \(baseline.baseline_cursor) of \(baseline.baseline_max_event_id) event positions").font(.footnote)
            }
            Button(store.network?.sync.preparing == true ? "Continue encrypted preparation" : "Enable encrypted sync") { confirmNetwork = true }
                .disabled(!store.available || store.busy || store.networkRunning || selectedDestination.isEmpty || store.network?.egress.kill_switch_enabled != false || store.entitlement?.sync_allowed != true)
            Button(store.networkRunning ? "Sync is running…" : "Run sync now") { Task { await store.runNetwork() } }
                .disabled(store.busy || store.networkRunning || store.stopping || store.network?.sync.enabled != true || store.entitlement?.sync_allowed != true)
            Button(store.stopping ? "Stopping…" : "Stop network sync", role: .destructive) { Task { await store.stopNetwork() } }
                .disabled(!store.available || store.stopping)
            Text("Stop waits for the current bounded request, then blocks the next send. No automatic background cycle runs.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var snapshotSection: some View {
        Section("Encrypted snapshots") {
            Button("Create and save encrypted snapshot") {
                Task { await store.exportSnapshot(); if let data = store.snapshotFile { export(data, name: "PeakActivity-encrypted-snapshot") } }
            }.disabled(!store.available || store.busy || store.networkRunning || store.recoveryActive)
            Button("Import recovery file") { startImport(.kit) }
            Button("Import encrypted snapshot") { startImport(.snapshot) }
            SecureField("Recovery phrase", text: $store.restorePhrase)
                .autocorrectionDisabled().textInputAutocapitalization(.never).privacySensitive()
            Button("Review encrypted restore") { Task { await store.previewRestore() } }
                .disabled(!store.canPreviewRestore)
            Button("Clear restore files and phrase", role: .cancel) { store.cancelRestore() }
            if let preview = store.restorePreview {
                Text("\(preview.object_count) encrypted objects · \(preview.tombstone_count) deletion records")
                Text("Activity range: \(preview.query_start ?? "empty") to \(preview.query_end ?? "empty")").font(.footnote)
                Text("Vault \(preview.vault_id) · Snapshot \(preview.snapshot_id)").font(.footnote).textSelection(.enabled)
                Text("Privacy conflicts: \(preview.policy_conflict_count)").font(.footnote)
                Button("Restore reviewed snapshot") { confirmRestore = true }.disabled(store.busy)
            }
            Text("Restore requires a clean sync vault and manual preparation Off. Existing offline entries and notes are preserved. Files are limited to 16 MiB.").font(.footnote).foregroundStyle(.secondary)
        }
        .disabled(!store.available || store.busy || store.networkRunning)
    }

    private func export(_ data: Data, name: String) {
        fileSession = store.sessionToken
        fileOperation = store.beginFileOperation()
        exportDocument = SyncFile(data: data)
        exportFilename = name
        exportFile = true
    }

    private func startImport(_ kind: ImportKind) {
        fileSession = store.sessionToken
        fileOperation = store.beginFileOperation()
        importKind = kind
        importFile = true
    }

    private var pairingInstruction: String {
        switch store.pairingStep {
        case .response: return "Receive the response to your invitation."
        case .offer: return "Receive the next message, then compare the verification codes."
        case .confirmation: return "Exchange confirmation messages after comparing codes on both devices."
        case .transfer: return "Receive the encrypted key transfer from the device that started pairing."
        default: return "Follow the pairing steps on both devices."
        }
    }
}
