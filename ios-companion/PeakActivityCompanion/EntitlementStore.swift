import Foundation
import Security

enum EntitlementStorageError: Error { case unavailable, invalidProof, invalidCheckpoint }

// Billing proof and its global checkpoint never share the activity vault's Keychain service.
final class EntitlementStore: @unchecked Sendable {
    static let maximumProofBytes = 4 * 1_048_576
    static let revocationScope = "entitlement-revocations-v1"
    private static let lock = NSRecursiveLock()
    private let service: String

    init(service: String = "app.peakactivity.entitlements.v1") { self.service = service }

    func load() throws -> Data? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let data = try read("signed-proof-v1") else { return nil }
        guard !data.isEmpty, data.count <= Self.maximumProofBytes else { throw EntitlementStorageError.invalidProof }
        return data
    }

    // Only the Rust verifier calls this callback after validating the signed document.
    func save(_ proof: Data) throws {
        guard !proof.isEmpty, proof.count <= Self.maximumProofBytes else { throw EntitlementStorageError.invalidProof }
        Self.lock.lock(); defer { Self.lock.unlock() }
        _ = try read("signed-proof-v1")
        try write("signed-proof-v1", data: proof)
    }

    func floor(scope: String) throws -> UInt64 {
        guard scope == Self.revocationScope else { throw EntitlementStorageError.invalidCheckpoint }
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let data = try read("revocation-floor-v1") else { return 0 }
        guard data.count == 8 else { throw EntitlementStorageError.invalidCheckpoint }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    func advance(scope: String, sequence: UInt64) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let previous = try floor(scope: scope)
        guard sequence >= previous else { throw EntitlementStorageError.invalidCheckpoint }
        guard sequence > previous else { return }
        var value = sequence.bigEndian
        let bytes = withUnsafeBytes(of: &value) { Data($0) }
        try write("revocation-floor-v1", data: bytes)
        guard try floor(scope: scope) >= sequence else { throw EntitlementStorageError.unavailable }
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              let data = item[kSecValueData as String] as? Data else { throw EntitlementStorageError.unavailable }
        return data
    }

    private func write(_ account: String, data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw EntitlementStorageError.unavailable }
        var add = query(account)
        attributes.forEach { add[$0.key] = $0.value }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw EntitlementStorageError.unavailable }
    }

    private static func source(_ context: UnsafeMutableRawPointer?) throws -> EntitlementStore {
        guard let context else { throw EntitlementStorageError.unavailable }
        return Unmanaged<EntitlementStore>.fromOpaque(context).takeUnretainedValue()
    }

    private static func scope(_ bytes: UnsafePointer<UInt8>?, _ length: Int) throws -> String {
        guard let bytes, (1...64).contains(length),
              let value = String(data: Data(bytes: bytes, count: length), encoding: .utf8),
              value == revocationScope else { throw EntitlementStorageError.invalidCheckpoint }
        return value
    }

    static func retainedCallbacks() -> PeakActivityEntitlementCallbacks {
        PeakActivityEntitlementCallbacks(
            context: Unmanaged.passRetained(EntitlementStore()).toOpaque(),
            load: { context, output, capacity, length in
                guard let length, capacity <= EntitlementStore.maximumProofBytes else { return -1 }
                length.pointee = 0
                do {
                    guard var proof = try EntitlementStore.source(context).load() else { return 1 }
                    defer { proof.resetBytes(in: 0..<proof.count) }
                    guard let output, proof.count <= capacity else { return -1 }
                    proof.copyBytes(to: output, count: proof.count)
                    length.pointee = proof.count
                    return 0
                } catch { return -1 }
            },
            save: { context, bytes, length in
                guard let bytes, (1...EntitlementStore.maximumProofBytes).contains(length) else { return -1 }
                var proof = Data(bytes: bytes, count: length)
                defer { proof.resetBytes(in: 0..<proof.count) }
                do { try EntitlementStore.source(context).save(proof); return 0 } catch { return -1 }
            },
            floor: { context, bytes, length, sequence in
                guard let sequence else { return -1 }
                do { sequence.pointee = try EntitlementStore.source(context).floor(scope: EntitlementStore.scope(bytes, length)); return 0 }
                catch { return -1 }
            },
            advance: { context, bytes, length, sequence in
                do { try EntitlementStore.source(context).advance(scope: EntitlementStore.scope(bytes, length), sequence: sequence); return 0 }
                catch { return -1 }
            },
            release: { context in
                if let context { Unmanaged<EntitlementStore>.fromOpaque(context).release() }
            })
    }
}
