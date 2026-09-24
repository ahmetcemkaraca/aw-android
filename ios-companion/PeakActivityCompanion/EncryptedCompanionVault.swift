import CryptoKit
import Foundation
import Security

enum CompanionVaultError: Error {
    case keyMissing
    case keyUnavailable
    case malformedKey
    case invalidEnvelope
    case secureStorageUnavailable
}

enum CompanionVaultCipher {
    static func seal<State: Encodable>(_ state: State, key: SymmetricKey) throws -> Data {
        var plaintext = try JSONEncoder().encode(state)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard let envelope = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CompanionVaultError.invalidEnvelope
        }
        return envelope
    }

    static func open<State: Decodable>(_ envelope: Data, key: SymmetricKey, as type: State.Type) throws -> State {
        let box = try AES.GCM.SealedBox(combined: envelope)
        var plaintext = try AES.GCM.open(box, using: key)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        return try JSONDecoder().decode(type, from: plaintext)
    }
}

struct EncryptedCompanionVault {
    private let fileURL: URL
    private let keychainService: String
    private let keychainAccount = "local-vault-key-v1"

    init(fileURL: URL? = nil, keychainService: String = Bundle.main.bundleIdentifier ?? "app.peakactivity.ioscompanion") throws {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw CompanionVaultError.secureStorageUnavailable
            }
            self.fileURL = support
                .appendingPathComponent("PeakActivityCompanion", isDirectory: true)
                .appendingPathComponent("local-vault-v1.bin")
        }
        self.keychainService = keychainService
    }

    func load() throws -> CompanionVaultState {
        guard try vaultFileExists() else {
            return CompanionVaultState()
        }
        let key = try loadKey(createIfMissing: false)
        let envelope = try Data(contentsOf: fileURL)
        do {
            return try CompanionVaultCipher.open(envelope, key: key, as: CompanionVaultState.self)
        } catch {
            throw CompanionVaultError.invalidEnvelope
        }
    }

    func save(_ state: CompanionVaultState) throws {
        let exists = try vaultFileExists()
        let key = try loadKey(createIfMissing: !exists)
        let envelope = try CompanionVaultCipher.seal(state, key: key)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try envelope.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path,
        )
        var protectedDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(resourceValues)
    }

    private func vaultFileExists() throws -> Bool {
        if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CompanionVaultError.secureStorageUnavailable
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func loadKey(createIfMissing: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard var bytes = result as? Data else {
                throw CompanionVaultError.malformedKey
            }
            guard bytes.count == 32 else {
                bytes.resetBytes(in: 0..<bytes.count)
                throw CompanionVaultError.malformedKey
            }
            let key = SymmetricKey(data: bytes)
            bytes.resetBytes(in: 0..<bytes.count)
            return key
        }
        guard status == errSecItemNotFound else { throw CompanionVaultError.keyUnavailable }
        guard createIfMissing else { throw CompanionVaultError.keyMissing }

        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
        }
        guard randomStatus == errSecSuccess else {
            bytes.resetBytes(in: 0..<bytes.count)
            throw CompanionVaultError.keyUnavailable
        }
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: bytes,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        addQuery[kSecValueData as String] = Data(repeating: 0, count: bytes.count)
        if addStatus == errSecSuccess {
            let key = SymmetricKey(data: bytes)
            bytes.resetBytes(in: 0..<bytes.count)
            return key
        }
        bytes.resetBytes(in: 0..<bytes.count)
        if addStatus == errSecDuplicateItem { return try loadKey(createIfMissing: false) }
        throw CompanionVaultError.keyUnavailable
    }
}
