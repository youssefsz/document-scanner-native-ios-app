import CryptoKit
import Foundation
import LocalAuthentication
import Security

nonisolated enum VaultAuthenticationError: LocalizedError, Equatable, Sendable {
    case cancelled
    case unavailable
    case lockedOut
    case authenticationFailed
    case keychain(OSStatus)
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .cancelled:
            nil
        case .unavailable:
            "Set a device passcode, Face ID, or Touch ID before using secure folders."
        case .lockedOut:
            "Authentication is locked. Unlock the device or try again later."
        case .authenticationFailed:
            "The secure folder could not be unlocked."
        case .keychain:
            "The encryption key could not be read from secure storage."
        case .invalidKey:
            "The encryption key in secure storage is invalid."
        }
    }
}

/// A folder-scoped, memory-only authority. Call `invalidate()` as soon as its
/// navigation session ends or protected data becomes unavailable.
nonisolated final class VaultAccess: @unchecked Sendable {
    let folderID: UUID
    let sessionID = UUID()

    private let lock = NSLock()
    private var rootKey: SymmetricKey?

    init(folderID: UUID, rootKey: SymmetricKey) {
        self.folderID = folderID
        self.rootKey = rootKey
    }

    var isValid: Bool {
        lock.withLock { rootKey != nil }
    }

    func invalidate() {
        lock.withLock { rootKey = nil }
    }

    func withRootKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        try lock.withLock {
            guard let rootKey else { throw LibraryRepositoryError.secureAccessRequired }
            return try body(rootKey)
        }
    }
}

nonisolated final class LocalAuthenticationService: @unchecked Sendable {
    func makeContext() throws -> LAContext {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw map(error)
        }
        return context
    }

    func authenticateFirstCreation(reason: String) async throws -> LAContext {
        let context = try makeContext()
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard success else { throw VaultAuthenticationError.authenticationFailed }
            return context
        } catch {
            throw map(error as NSError)
        }
    }

    func map(_ error: NSError?) -> VaultAuthenticationError {
        guard let error else { return .unavailable }
        guard error.domain == LAError.errorDomain, let code = LAError.Code(rawValue: error.code) else {
            return .authenticationFailed
        }
        switch code {
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .biometryLockout:
            return .lockedOut
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet, .notInteractive:
            return .unavailable
        default:
            return .authenticationFailed
        }
    }
}

actor VaultKeyStore {
    private let service: String
    private let account = "root-key-v1"
    private let authentication: LocalAuthenticationService

    init(
        service: String = "com.youssefdhibi.DocScanner.vault.v1",
        authentication: LocalAuthenticationService = LocalAuthenticationService()
    ) {
        self.service = service
        self.authentication = authentication
    }

    /// Creates the single app root key lazily. Existing keys are retrieved with
    /// the supplied LAContext so Keychain presents exactly one system prompt.
    func access(folderID: UUID, reason: String) async throws -> VaultAccess {
        let exists = try itemExistsWithoutPrompt()
        let context: LAContext

        if exists {
            context = try authentication.makeContext()
        } else {
            context = try await authentication.authenticateFirstCreation(reason: reason)
        }

        let key = exists
            ? try readKey(context: context, reason: reason)
            : try createKey(context: context)
        return VaultAccess(folderID: folderID, rootKey: key)
    }

    private func itemExistsWithoutPrompt() throws -> Bool {
        var query = baseQuery
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw VaultAuthenticationError.keychain(status)
        }
    }

    private func createKey(context: LAContext) throws -> SymmetricKey {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlocked,
            .userPresence,
            &accessError
        ) else {
            throw VaultAuthenticationError.authenticationFailed
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        var query = baseQuery
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecValueData as String] = keyData
        query[kSecUseAuthenticationContext as String] = context

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return try readKey(context: context, reason: "Unlock secure folders")
        }
        guard status == errSecSuccess else { throw mapKeychainStatus(status) }
        return key
    }

    private func readKey(context: LAContext, reason: String) throws -> SymmetricKey {
        context.localizedReason = reason
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw mapKeychainStatus(status) }
        guard let data = result as? Data, data.count == 32 else {
            throw VaultAuthenticationError.invalidKey
        }
        return SymmetricKey(data: data)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func mapKeychainStatus(_ status: OSStatus) -> VaultAuthenticationError {
        switch status {
        case errSecUserCanceled:
            .cancelled
        case errSecInteractionNotAllowed, errSecNotAvailable:
            .unavailable
        case errSecAuthFailed:
            .authenticationFailed
        default:
            .keychain(status)
        }
    }
}

nonisolated private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
