import Foundation
import Darwin

enum NativeSyncError: Error {
    case unavailable
    case invalidRequest
    case invalidResponse
    case operationFailed(String)
}

struct NativeNetworkStatus: Decodable, Sendable {
    struct Sync: Decodable, Sendable {
        struct Baseline: Decodable, Sendable {
            let baseline_cursor: UInt64
            let baseline_max_event_id: UInt64
            let complete: Bool
        }
        let enabled: Bool
        let destination_id: String?
        let purpose_id: String?
        let preparing: Bool
        let baseline: Baseline?
    }
    struct Egress: Decodable, Sendable {
        let kill_switch_enabled: Bool
        let trusted_policy_keys: Int
        let outbound_enabled: Bool
        let policy_bundle_version: UInt64?
    }
    let sync: Sync
    let egress: Egress
    let running: Bool
}

struct NativeSyncDestination: Decodable, Identifiable, Sendable {
    let destination_id: String
    let label: String
    let purpose_id: String
    let retention_disclosure: String
    let allowed_fields: [String]
    var id: String { destination_id }
}

struct NativeSyncRunResult: Decodable, Sendable {
    let success: Bool
    let retryable: Bool
    let error: String?
}

struct NativeEntitlementStatus: Decodable, Sendable {
    let plan_id: String
    let feature_ids: [String]
    let expires_at: UInt64
    let grace_until: UInt64
    let access: String
    let sync_allowed: Bool
}

struct NativeRestorePreview: Decodable, Sendable {
    let snapshot_id: String
    let vault_id: String
    let object_count: Int
    let tombstone_count: Int
    let query_start: String?
    let query_end: String?
    let policy_conflict_count: Int
}

actor NativeSyncClient {
    private nonisolated let handle: UInt64
    private var closed = false

    private init(vault: EncryptedCompanionVault) throws {
        guard let resource = Bundle.main.url(forResource: "release-trust", withExtension: "json") else {
            throw NativeSyncError.unavailable
        }
        let trust = try Data(contentsOf: resource)
        let entitlementResource = Bundle.main.url(forResource: "entitlement-trust", withExtension: "json")
        let entitlementData = entitlementResource.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let entitlementTrust = entitlementData.count <= 16_384 ? entitlementData : Data()
        guard trust.count <= 16_384 else { throw NativeSyncError.invalidRequest }
        handle = try vault.withSyncKey { path, key in
            let pathBytes = Data(path.utf8)
            return pathBytes.withUnsafeBytes { pathBuffer in
                key.withUnsafeBytes { keyBuffer in
                    trust.withUnsafeBytes { trustBuffer in
                        entitlementTrust.withUnsafeBytes { entitlementBuffer in
                            peakactivity_companion_open_with_security(
                                pathBuffer.bindMemory(to: UInt8.self).baseAddress, pathBuffer.count,
                                keyBuffer.bindMemory(to: UInt8.self).baseAddress, keyBuffer.count,
                                trustBuffer.bindMemory(to: UInt8.self).baseAddress, trustBuffer.count,
                                entitlementBuffer.bindMemory(to: UInt8.self).baseAddress, entitlementBuffer.count,
                                EntitlementStore.retainedCallbacks()
                            )
                        }
                    }
                }
            }
        }
        guard handle != 0 else { throw NativeSyncError.unavailable }
    }

    static func open(vault: EncryptedCompanionVault) async throws -> NativeSyncClient {
        try await Task.detached(priority: .userInitiated) { try NativeSyncClient(vault: vault) }.value
    }

    deinit { if !closed { _ = peakactivity_companion_close(handle) } }

    @discardableResult
    func close() -> Bool {
        guard !closed else { return true }
        guard peakactivity_companion_close(handle) else { return false }
        closed = true
        return true
    }

    // The Rust registry owns handle lifetime; stop bypasses a running relay cycle.
    nonisolated func pause() async -> Bool {
        await Task.detached(priority: .userInitiated) { peakactivity_companion_pause_sync(self.handle) }.value
    }

    nonisolated func runSyncOnce() async throws -> NativeSyncRunResult {
        try await Task.detached(priority: .userInitiated) {
            var bytes = try Self.call(self.handle, "run_sync_once", arguments: Data("{}".utf8))
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            return try JSONDecoder().decode(NativeSyncRunResult.self, from: bytes)
        }.value
    }

    func invoke<Result: Decodable & Sendable>(_ command: String, arguments: Data = Data("{}".utf8), as: Result.Type) throws -> Result {
        var bytes = try invokeJSON(command, arguments: arguments)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try JSONDecoder().decode(Result.self, from: bytes)
    }

    func invokeJSON(_ command: String, arguments: Data = Data("{}".utf8)) throws -> Data {
        guard !closed else { throw NativeSyncError.unavailable }
        return try Self.call(handle, command, arguments: arguments)
    }

    private nonisolated static func call(_ handle: UInt64, _ command: String, arguments: Data) throws -> Data {
        guard arguments.count <= 16 * 1_048_576,
              let value = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw NativeSyncError.invalidRequest
        }
        var request = try JSONSerialization.data(withJSONObject: ["command": command, "arguments": value])
        defer { request.resetBytes(in: 0..<request.count) }
        guard request.count <= 16 * 1_048_576 else { throw NativeSyncError.invalidRequest }
        let pointer = request.withUnsafeBytes { buffer in
            peakactivity_companion_invoke(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
        }
        guard let pointer else { throw NativeSyncError.invalidResponse }
        defer { peakactivity_companion_response_free(pointer) }
        var bytes = Data(bytes: pointer, count: strlen(pointer))
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw NativeSyncError.invalidResponse
        }
        if let error = response["error"] as? String { throw NativeSyncError.operationFailed(error) }
        guard let result = response["result"] else { throw NativeSyncError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys])
    }
}
