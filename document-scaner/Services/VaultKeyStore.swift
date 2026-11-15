import CryptoKit
import Foundation
import LocalAuthentication
import Security
import UIKit

nonisolated enum VaultAuthenticationError: LocalizedError, Equatable, Sendable {
    case cancelled
    case unavailable
    case lockedOut
    case authenticationFailed
    case keychain(OSStatus)
    case invalidKey
    case deviceLocked
    case signing
    case libraryUnavailable
    case busy
    case recoveryRequired
    case keyConflict

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
        case .deviceLocked:
            "Unlock this device before accessing the secure folder."
        case .signing:
            "This build cannot access the secure folder’s App Group. Update DocScanner or contact support."
        case .libraryUnavailable:
            "Wait for the library to finish loading and try again."
        case .busy:
            "Another secure folder operation is in progress. Try again when it finishes."
        case .recoveryRequired:
            "The original key is unavailable. Your encrypted documents are still on this device. Restore a vault backup with its recovery code."
        case .keyConflict:
            "The vault keys do not match. Both keys and your documents were kept. Contact support before making changes."
        }
    }
}

/// A folder-scoped, memory-only authority. Call `invalidate()` as soon as its
/// navigation session ends or protected data becomes unavailable.
nonisolated final class VaultAccess: @unchecked Sendable {
    let folderID: UUID
    let sessionID = UUID()
    let transferStatus: VaultTransferStatus

    private let lock = NSLock()
    private var rootKey: SymmetricKey?

    init(folderID: UUID, rootKey: SymmetricKey, transferStatus: VaultTransferStatus = .ready) {
        self.folderID = folderID
        self.transferStatus = transferStatus
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

    func authenticate(_ context: LAContext, reason: String) async throws {
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard success else { throw VaultAuthenticationError.authenticationFailed }
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

nonisolated enum VaultTransferStatus: Equatable, Sendable {
    case ready
    case pending(VaultAuthenticationError)
}

nonisolated enum VaultKeyLocation: Sendable {
    case legacy
    case appGroup
}

nonisolated protocol VaultKeyStorage: Sendable {
    func read(_ location: VaultKeyLocation, context: LAContext, reason: String) throws -> SymmetricKey?
    /// Insert only. A concurrent or interrupted previous write is resolved by reading back.
    func addToAppGroup(_ key: SymmetricKey, context: LAContext) throws
}

actor VaultKeyStore {
    static let appGroup = "group.tn.document-scaner.app.vault"
    private let storage: any VaultKeyStorage
    private let makeContext: @Sendable () throws -> LAContext
    private let authenticate: @Sendable (LAContext, String) async throws -> Void
    private let protectedDataAvailable: @MainActor @Sendable () -> Bool
    private var isWorking = false

    init(
        storage: any VaultKeyStorage = SystemVaultKeyStorage(),
        makeContext: @escaping @Sendable () throws -> LAContext = { try LocalAuthenticationService().makeContext() },
        authenticate: @escaping @Sendable (LAContext, String) async throws -> Void = {
            try await LocalAuthenticationService().authenticate($0, reason: $1)
        },
        protectedDataAvailable: @escaping @MainActor @Sendable () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    ) {
        self.storage = storage
        self.makeContext = makeContext
        self.authenticate = authenticate
        self.protectedDataAvailable = protectedDataAvailable
    }

    func openExisting(folderID: UUID, reason: String) async throws -> VaultAccess {
        try await access(folderID: folderID, reason: reason, confirmEmpty: nil)
    }

    /// Only callers creating secure content may supply a fresh, unfiltered inventory check.
    func prepareForCreation(
        folderID: UUID,
        reason: String,
        confirmEmpty: @escaping @Sendable () async throws -> Bool
    ) async throws -> VaultAccess {
        try await access(folderID: folderID, reason: reason, confirmEmpty: confirmEmpty)
    }

    private func access(
        folderID: UUID,
        reason: String,
        confirmEmpty: (@Sendable () async throws -> Bool)?
    ) async throws -> VaultAccess {
        try beginOperation()
        defer { isWorking = false }
        guard await protectedDataAvailable() else { throw VaultAuthenticationError.deviceLocked }
        let context = try makeContext()
        defer { context.invalidate() }

        let shared: SymmetricKey?
        do {
            shared = try storage.read(.appGroup, context: context, reason: reason)
        } catch VaultAuthenticationError.signing {
            // The legacy item remains usable for backup even if this build cannot
            // finish migration. Never treat an unavailable group as an empty vault.
            guard let legacy = try storage.read(.legacy, context: context, reason: reason) else {
                throw VaultAuthenticationError.signing
            }
            try await checkActive()
            return VaultAccess(folderID: folderID, rootKey: legacy, transferStatus: .pending(.signing))
        }

        let legacy = try storage.read(.legacy, context: context, reason: reason)
        try await checkActive()
        if let shared {
            if let legacy, legacy != shared { throw VaultAuthenticationError.keyConflict }
            return VaultAccess(folderID: folderID, rootKey: shared)
        }
        if let legacy {
            do {
                try install(legacy, context: context, reason: reason)
            } catch let error as VaultAuthenticationError {
                switch error {
                case .keychain, .signing:
                    return VaultAccess(folderID: folderID, rootKey: legacy, transferStatus: .pending(error))
                default:
                    throw error
                }
            }
            return VaultAccess(folderID: folderID, rootKey: legacy)
        }

        guard let confirmEmpty, try await confirmEmpty() else { throw VaultAuthenticationError.recoveryRequired }
        try await authenticate(context, reason)
        try await checkActive()
        guard try await confirmEmpty() else { throw VaultAuthenticationError.recoveryRequired }
        try await checkActive()
        let key = SymmetricKey(size: .bits256)
        try install(key, context: context, reason: reason)
        return VaultAccess(folderID: folderID, rootKey: key)
    }

    /// Used only after the backup and local vault data have been authenticated.
    func installRecoveredKey(_ key: SymmetricKey, requireExistingMatch: Bool = false) async throws {
        try beginOperation()
        defer { isWorking = false }
        guard await protectedDataAvailable() else { throw VaultAuthenticationError.deviceLocked }
        let context = try makeContext()
        defer { context.invalidate() }
        let reason = "Restore your secure folder backup"
        let shared = try storage.read(.appGroup, context: context, reason: reason)
        let legacy = try storage.read(.legacy, context: context, reason: reason)
        if let shared, shared != key { throw VaultAuthenticationError.keyConflict }
        if let legacy, legacy != key { throw VaultAuthenticationError.keyConflict }
        if requireExistingMatch, shared == nil, legacy == nil { throw VaultAuthenticationError.recoveryRequired }
        if shared == nil, legacy == nil { try await authenticate(context, reason) }
        try await checkActive()
        if shared == nil { try install(key, context: context, reason: reason) }
    }

    private func beginOperation() throws {
        guard !isWorking else { throw VaultAuthenticationError.busy }
        isWorking = true
    }

    private func checkActive() async throws {
        try Task.checkCancellation()
        guard await protectedDataAvailable() else { throw VaultAuthenticationError.deviceLocked }
        try Task.checkCancellation()
    }

    private func install(_ key: SymmetricKey, context: LAContext, reason: String) throws {
        try Task.checkCancellation()
        try storage.addToAppGroup(key, context: context)
        guard let persisted = try storage.read(.appGroup, context: context, reason: reason) else {
            throw VaultAuthenticationError.keychain(errSecItemNotFound)
        }
        guard persisted == key else { throw VaultAuthenticationError.keyConflict }
    }
}

nonisolated struct SystemVaultKeyStorage: VaultKeyStorage {
    let service: String
    private let group: String

    init(service: String = "com.youssefdhibi.DocScanner.vault.v1", group: String = VaultKeyStore.appGroup) {
        self.service = service
        self.group = group
    }

    func read(_ location: VaultKeyLocation, context: LAContext, reason: String) throws -> SymmetricKey? {
        context.localizedReason = reason
        var query = baseQuery(location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            // A read for an unauthorized group can also return item-not-found.
            if location == .appGroup,
               FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) == nil {
                throw VaultAuthenticationError.signing
            }
            return nil
        }
        guard status == errSecSuccess else { throw map(status) }
        guard let data = result as? Data, data.count == 32 else { throw VaultAuthenticationError.invalidKey }
        return SymmetricKey(data: data)
    }

    func addToAppGroup(_ key: SymmetricKey, context: LAContext) throws {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlocked, .userPresence, &accessError) else {
            _ = accessError?.takeRetainedValue()
            throw VaultAuthenticationError.authenticationFailed
        }
        var query = baseQuery(.appGroup)
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw map(status) }
    }

    private func baseQuery(_ location: VaultKeyLocation) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // The legacy selector is unscoped because older builds used the
            // signing identity’s default group. The distinct account guarantees
            // the new App Group item can never satisfy that selector.
            kSecAttrAccount as String: location == .legacy ? "root-key-v1" : "root-key-v1-app-group"
        ]
        if location == .appGroup { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    private func map(_ status: OSStatus) -> VaultAuthenticationError {
        switch status {
        case errSecUserCanceled: .cancelled
        case errSecInteractionNotAllowed, errSecNotAvailable: .deviceLocked
        case errSecAuthFailed: .authenticationFailed
        case errSecMissingEntitlement: .signing
        default: .keychain(status)
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
