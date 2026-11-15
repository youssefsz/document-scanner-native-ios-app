import Combine
import SwiftUI
import UIKit

@MainActor
final class DocumentLibrary: ObservableObject {
    @Published private(set) var documents: [ScannedDocument] = []
    @Published private(set) var allDocuments: [ScannedDocument] = []
    @Published private(set) var folders: [FolderSummary] = []
    @Published private(set) var allFolders: [FolderSummary] = []
    @Published private(set) var loadState: LibraryLoadState = .initialLoading
    @Published private(set) var activeOperations: Set<LibraryOperation> = []
    @Published private(set) var mutationsEnabled = false
    @Published private(set) var isDocumentSearchPending = false
    @Published private(set) var isFolderSearchPending = false
    @Published var activeError: LibraryError?
    @Published var selectedSection: LibrarySection = .library
    @Published var librarySearchQuery = ""
    @Published var folderSearchQuery = ""
    @Published private(set) var securityConversionProgress: [UUID: SecurityConversionProgress] = [:]
    @Published private(set) var isAuthenticatingSecureContent = false
    @Published private(set) var vaultTransferStatus: VaultTransferStatus?
    @Published private(set) var hasVerifiedVaultTransfer: Bool

    private let repository: any LibraryRepository
    private let store: DocumentStore
    private let securityCoordinator: DocumentSecurityCoordinator?
    private let securityRepository: (any DocumentSecurityRepository)?
    private let vaultKeyStore: VaultKeyStore
    private let vaultBackup: VaultBackupService?
    private let preferences: UserDefaults
    private let secureSessions: SecureFolderSessionController
    private let contentProvider: any DocumentContentProviding
    private let proAccess: any ProAccessProviding
    private let vaultCrypto = VaultCryptoService()
    private var hasLoaded = false
    private var sortOrder: LibrarySortOrder = .newestFirst
    private var documentSearchTask: Task<Void, Never>?
    private var folderSearchTask: Task<Void, Never>?
    private var securityConversionTasks: [UUID: Task<Void, Error>] = [:]
    private var secureAuthenticationCount = 0
    private var secureMutationCount = 0
    private var isVaultMaintenanceActive = false
    private var isReloading = false
    private var vaultLockGeneration = 0

    var secureFolderForTransferReminder: DocumentFolder? {
        guard VaultTransferReminder.isEnabled, hasLoaded, !hasVerifiedVaultTransfer else { return nil }
        return allFolders.first { $0.folder.isSecure }?.folder
    }

    var isLoading: Bool {
        switch loadState {
        case .initialLoading, .migrating:
            true
        default:
            false
        }
    }

    init(
        repository: (any LibraryRepository)? = nil,
        store: DocumentStore? = nil,
        securityCoordinator: DocumentSecurityCoordinator? = nil,
        vaultKeyStore: VaultKeyStore = VaultKeyStore(),
        vaultPaths: StoragePaths = .production,
        secureSessions: SecureFolderSessionController? = nil,
        contentProvider: any DocumentContentProviding = DocumentContentProvider(),
        proAccess: (any ProAccessProviding)? = nil,
        preferences: UserDefaults = .standard
    ) {
        let resolvedRepository = repository ?? CoreDataLibraryRepository()
        self.repository = resolvedRepository
        self.store = store ?? DocumentStore(repository: resolvedRepository)
        self.vaultKeyStore = vaultKeyStore
        self.preferences = preferences
        self.hasVerifiedVaultTransfer = preferences.bool(forKey: AppPreferenceKey.vaultTransferVerified)
        vaultBackup = (resolvedRepository as? any VaultRecoveryRepository).map {
            VaultBackupService(repository: $0, paths: vaultPaths, keys: vaultKeyStore)
        }
        self.secureSessions = secureSessions ?? SecureFolderSessionController()
        self.contentProvider = contentProvider
        self.proAccess = proAccess ?? FreeProAccessProvider()
        if let securityCoordinator {
            self.securityCoordinator = securityCoordinator
        } else if let securityRepository = resolvedRepository as? any DocumentSecurityRepository {
            self.securityCoordinator = DocumentSecurityCoordinator(repository: securityRepository)
        } else {
            self.securityCoordinator = nil
        }
        self.securityRepository = resolvedRepository as? any DocumentSecurityRepository
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard !isVaultMaintenanceActive, !isReloading else { return }
        isReloading = true
        hasLoaded = false
        mutationsEnabled = false
        defer { isReloading = false }
        documentSearchTask?.cancel()
        folderSearchTask?.cancel()
        isDocumentSearchPending = false
        isFolderSearchPending = false
        loadState = .initialLoading
        activeError = nil

        do {
            guard UIApplication.shared.isProtectedDataAvailable else { throw VaultAuthenticationError.deviceLocked }
            if try await repository.needsLegacyMigration() {
                loadState = .migrating
            }
            try await repository.bootstrap()
            try await securityCoordinator?.recoverInterruptedOperations()
            try await refreshAll()
            hasLoaded = true
            mutationsEnabled = true
        } catch {
            documents = await repository.loadLegacyFallback()
            allDocuments = documents
            mutationsEnabled = false
            hasLoaded = false
            loadState = .migrationFailed(error.localizedDescription)
        }
    }

    func retryMigration() async {
        await reload()
    }

    func updateSortOrder(rawValue: String) {
        let setting = DocumentSortOrder(rawValue: rawValue) ?? .newestFirst
        sortOrder = setting == .oldestFirst ? .oldestFirst : .newestFirst
        scheduleDocumentSearch(immediate: true)
    }

    func updateLibrarySearch(_ query: String) {
        librarySearchQuery = query
        if LibraryTextNormalizer.normalize(query).isEmpty {
            documentSearchTask?.cancel()
            isDocumentSearchPending = false
            documents = allDocuments
            loadState = allDocuments.isEmpty && allFolders.isEmpty ? .empty : .loaded
            return
        }
        scheduleDocumentSearch(immediate: false)
    }

    func updateFolderSearch(_ query: String) {
        folderSearchQuery = query
        if LibraryTextNormalizer.normalize(query).isEmpty {
            folderSearchTask?.cancel()
            isFolderSearchPending = false
            folders = allFolders
            loadState = allDocuments.isEmpty && allFolders.isEmpty ? .empty : .loaded
            return
        }
        scheduleFolderSearch(immediate: false)
    }

    func importScan(
        pages: [UIImage],
        title: String? = nil,
        folderID: UUID? = nil
    ) async {
        guard mutationsEnabled,
              !activeOperations.contains(.savingScan),
              folderID.map({ securityConversionTasks[$0] == nil }) ?? true else { return }
        if let folderID,
           allFolders.first(where: { $0.id == folderID })?.folder.isSecure == true,
           !requirePro(.secureFolder) {
            return
        }
        activeOperations.insert(.savingScan)
        defer { activeOperations.remove(.savingScan) }

        do {
            _ = try await store.saveScan(pages: pages, title: title, folderID: folderID)
            try await refreshAll()
            activeError = nil
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
        }
    }

    func rename(_ document: ScannedDocument, title: String) async {
        guard mutationsEnabled else { return }
        do {
            try await repository.renameDocument(id: document.id, title: title)
            try await refreshAll()
            activeError = nil
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
        }
    }

    func renameSecure(_ document: ScannedDocument, title: String, access: VaultAccess) async -> Bool {
        guard mutationsEnabled else { return false }
        secureMutationCount += 1
        defer { secureMutationCount -= 1 }
        guard let securityCoordinator else { return false }
        do {
            try await securityCoordinator.renameSecureDocument(document, title: title, access: access)
            activeError = nil
            return true
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func delete(_ document: ScannedDocument) async {
        await delete([document])
    }

    func delete(_ documents: [ScannedDocument]) async {
        guard mutationsEnabled, !documents.isEmpty, !activeOperations.contains(.deletingDocuments) else { return }
        activeOperations.insert(.deletingDocuments)
        defer { activeOperations.remove(.deletingDocuments) }

        do {
            try await repository.deleteDocuments(ids: Set(documents.map(\.id)))
            try await refreshAll()
            activeError = nil
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
        }
    }

    func deleteSecure(_ document: ScannedDocument, access: VaultAccess) async -> Bool {
        await deleteSecure([document], access: access)
    }

    func deleteSecure(_ documents: [ScannedDocument], access: VaultAccess) async -> Bool {
        guard mutationsEnabled else { return false }
        secureMutationCount += 1
        defer { secureMutationCount -= 1 }
        guard let securityCoordinator else { return false }
        do {
            guard !documents.isEmpty,
                  let folderID = documents.first?.folderID,
                  documents.allSatisfy({ $0.folderID == folderID }) else { return false }
            try await securityCoordinator.deleteSecureDocuments(documents, folderID: folderID, access: access)
            activeError = nil
            try await refreshAll()
            return true
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func moveSecureDocuments(
        ids: Set<UUID>,
        from sourceFolderID: UUID,
        to destinationFolderID: UUID?,
        access: VaultAccess
    ) async -> Bool {
        guard mutationsEnabled else { return false }
        secureMutationCount += 1
        defer { secureMutationCount -= 1 }
        guard let securityCoordinator else { return false }
        let destination = destinationFolderID.flatMap { id in allFolders.first(where: { $0.id == id })?.folder }
        if destinationFolderID != nil, destination == nil {
            activeError = LibraryError(message: LibraryRepositoryError.missingFolder.localizedDescription)
            return false
        }
        if destination?.isSecure == true, !requirePro(.secureFolder) { return false }
        do {
            try await securityCoordinator.moveSecureDocuments(
                ids: ids,
                sourceFolderID: sourceFolderID,
                destination: destination,
                access: access
            )
            try await refreshAll()
            activeError = nil
            return true
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func addNormalDocumentsToSecure(
        ids: Set<UUID>,
        destination: DocumentFolder,
        access: VaultAccess
    ) async -> Bool {
        guard mutationsEnabled else { return false }
        secureMutationCount += 1
        defer { secureMutationCount -= 1 }
        guard requirePro(.secureFolder), let securityCoordinator else { return false }
        let documents = allDocuments.filter { ids.contains($0.id) }
        guard documents.count == ids.count else { return false }
        do {
            try await securityCoordinator.moveNormalDocumentsToSecure(
                documents,
                destination: destination,
                access: access
            )
            try await refreshAll()
            activeError = nil
            return true
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func importSecureScan(
        pages: [UIImage],
        title: String,
        destination: DocumentFolder,
        access: VaultAccess
    ) async -> Bool {
        guard mutationsEnabled else { return false }
        secureMutationCount += 1
        defer { secureMutationCount -= 1 }
        guard requirePro(.secureFolder), let securityCoordinator else { return false }
        do {
            let prepared = try await store.prepareSecureScan(
                pages: pages,
                title: title,
                folderID: destination.id
            )
            do {
                try await securityCoordinator.importPreparedSecureScan(
                    prepared,
                    destination: destination,
                    access: access
                )
                await store.discardPreparedSecureScan(prepared)
            } catch {
                await store.discardPreparedSecureScan(prepared)
                throw error
            }
            try await refreshAll()
            activeError = nil
            return true
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func createFolder(name: String, security: FolderSecurity = .standard) async -> Bool {
        guard mutationsEnabled, !activeOperations.contains(.creatingFolder) else { return false }
        guard security != .secure || requirePro(.secureFolder) else { return false }
        let submittedName = LibraryTextNormalizer.ownedCopy(name)
        activeOperations.insert(.creatingFolder)
        defer { activeOperations.remove(.creatingFolder) }

        do {
            if security == .secure {
                let creationAccess = try await vaultAccess(
                    folderID: UUID(), reason: "Create a secure folder", allowsCreation: true
                )
                creationAccess.invalidate()
            }
            _ = try await repository.createFolder(name: submittedName, security: security)
            try await refreshAll()
            activeError = nil
            AccessibilityNotification.announce("Folder created")
            return true
        } catch {
            if error as? VaultAuthenticationError == .cancelled { return false }
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func unlockSecureFolder(_ folder: DocumentFolder) async throws -> VaultAccess {
        guard folder.isSecure else { throw LibraryRepositoryError.invalidSecurityState }
        guard hasLoaded, !isReloading, !isVaultMaintenanceActive else {
            throw VaultAuthenticationError.libraryUnavailable
        }
        if let existing = secureSessions.access(for: folder.id) { return existing }
        do {
            let access = try await vaultAccess(folderID: folder.id, reason: "Unlock secure folder")
            secureSessions.begin(access)
            return access
        } catch {
            if (error as? VaultAuthenticationError) != .cancelled { vaultTransferStatus = nil }
            throw error
        }
    }

    private func vaultAccess(folderID: UUID, reason: String, allowsCreation: Bool = false) async throws -> VaultAccess {
        guard hasLoaded, !isReloading else { throw VaultAuthenticationError.libraryUnavailable }
        beginSecureAuthentication()
        defer { endSecureAuthentication() }

        let lockGeneration = vaultLockGeneration
        let access: VaultAccess
        if allowsCreation {
            guard let vaultBackup else { throw VaultAuthenticationError.libraryUnavailable }
            access = try await vaultKeyStore.prepareForCreation(folderID: folderID, reason: reason) {
                try await vaultBackup.confirmEmpty()
            }
        } else {
            access = try await vaultKeyStore.openExisting(folderID: folderID, reason: reason)
        }
        guard lockGeneration == vaultLockGeneration, !Task.isCancelled else {
            access.invalidate()
            throw CancellationError()
        }
        recordVaultTransferStatus(access.transferStatus)
        return access
    }

    func makeVaultBackup() async throws -> VaultBackup {
        guard let vaultBackup else { throw VaultAuthenticationError.libraryUnavailable }
        try beginVaultMaintenance()
        defer { endVaultMaintenance() }
        let backup = try await vaultBackup.makeBackup()
        recordVaultTransferStatus(backup.transferStatus)
        return backup
    }

    func restoreVault(from url: URL, code: String) async throws -> VaultRestoreResult {
        guard let vaultBackup else { throw VaultAuthenticationError.libraryUnavailable }
        try beginVaultMaintenance()
        defer { endVaultMaintenance() }
        let result = try await vaultBackup.restore(from: url, recoveryCode: code)
        lockAllSecureFolders()
        recordVaultTransferStatus(.ready)
        // The restore committed. A transient refresh error must not look like
        // a failed restore; the next library load will read the committed data.
        do {
            try await refreshAll()
        } catch {
            hasLoaded = false
            loadState = .failed(error.localizedDescription)
        }
        return result
    }

    private func recordVaultTransferStatus(_ status: VaultTransferStatus) {
        vaultTransferStatus = status
        guard status == .ready, !hasVerifiedVaultTransfer else { return }
        // Historical UI state only. Unlock still verifies the actual Keychain item.
        preferences.set(true, forKey: AppPreferenceKey.vaultTransferVerified)
        hasVerifiedVaultTransfer = true
    }

    private func beginVaultMaintenance() throws {
        guard hasLoaded, mutationsEnabled, !isReloading else { throw VaultAuthenticationError.libraryUnavailable }
        guard activeOperations.isEmpty, secureMutationCount == 0, secureAuthenticationCount == 0 else {
            throw VaultAuthenticationError.busy
        }
        isVaultMaintenanceActive = true
        mutationsEnabled = false
        beginSecureAuthentication()
    }

    private func endVaultMaintenance() {
        endSecureAuthentication()
        isVaultMaintenanceActive = false
        mutationsEnabled = hasLoaded
    }

    private func beginSecureAuthentication() {
        secureAuthenticationCount += 1
        isAuthenticatingSecureContent = true
    }

    private func endSecureAuthentication() {
        secureAuthenticationCount = max(0, secureAuthenticationCount - 1)
        isAuthenticatingSecureContent = secureAuthenticationCount > 0
    }

    func lockSecureFolder(id: UUID) {
        secureSessions.invalidate(folderID: id)
        Task { await SecureThumbnailPipeline.shared.clearAll() }
    }

    func activeSecureFolderAccess(for folderID: UUID) -> VaultAccess? {
        secureSessions.access(for: folderID)
    }

    func lockAllSecureFolders() {
        vaultLockGeneration &+= 1
        securityConversionTasks.values.forEach { $0.cancel() }
        securityConversionTasks.removeAll()
        secureSessions.invalidateAll()
        securityConversionProgress.removeAll()
        librarySearchQuery = ""
        Task { await SecureThumbnailPipeline.shared.clearAll() }
    }

    func changeFolderSecurity(_ folder: DocumentFolder, to target: FolderSecurity) async -> Bool {
        guard mutationsEnabled else { return false }
        secureMutationCount += 1
        defer { secureMutationCount -= 1 }
        guard target != .secure || requirePro(.secureFolder) else { return false }
        guard let securityCoordinator,
              !securityConversionTasks.keys.contains(folder.id) else { return false }
        do {
            let access = try await vaultAccess(
                folderID: folder.id,
                reason: target == .secure ? "Make folder secure" : "Remove folder security",
                allowsCreation: target == .secure && !folder.isSecure
            )
            secureSessions.begin(access)
            let task = Task { [self] in
                try await securityCoordinator.convertFolder(id: folder.id, to: target, access: access) { progress in
                    Task { @MainActor [weak self] in
                        self?.securityConversionProgress[folder.id] = progress
                    }
                }
            }
            securityConversionTasks[folder.id] = task
            try await task.value
            securityConversionTasks.removeValue(forKey: folder.id)
            securityConversionProgress.removeValue(forKey: folder.id)
            lockSecureFolder(id: folder.id)
            try await refreshAll()
            return true
        } catch {
            securityConversionTasks.removeValue(forKey: folder.id)
            securityConversionProgress.removeValue(forKey: folder.id)
            lockSecureFolder(id: folder.id)
            if error is CancellationError || error as? VaultAuthenticationError == .cancelled { return false }
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func cancelSecurityConversion(folderID: UUID) {
        securityConversionTasks[folderID]?.cancel()
    }

    func isFolderConverting(_ id: UUID) -> Bool {
        securityConversionTasks[id] != nil
    }

    func secureFolderDocuments(folderID: UUID, access: VaultAccess) async throws -> [ScannedDocument] {
        guard access.folderID == folderID, access.isValid, let securityRepository else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        let snapshot = try await securityRepository.securitySnapshot(folderID: folderID)
        guard snapshot.folder.isSecure else { throw LibraryRepositoryError.invalidSecurityState }
        return try await Task.detached { [vaultCrypto] in
            try snapshot.documents.map { record in
                guard let titleBlob = record.secureTitleBlob else {
                    throw LibraryRepositoryError.invalidSecurityState
                }
                let title = try vaultCrypto.decryptTitle(titleBlob, documentID: record.document.id, access: access)
                return ScannedDocument(
                    id: record.document.id,
                    title: title,
                    createdAt: record.document.createdAt,
                    pageCount: record.document.pageCount,
                    pdfFilename: record.document.pdfFilename,
                    previewFilename: record.document.previewFilename,
                    folderID: record.document.folderID,
                    protection: record.document.protection,
                    protectionFormatVersion: record.document.protectionFormatVersion
                )
            }
        }.value
    }

    func secureAssetData(
        for document: ScannedDocument,
        kind: VaultAssetKind,
        access: VaultAccess
    ) async throws -> Data {
        guard document.isSecure, access.isValid, document.folderID == access.folderID else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        return try await contentProvider.data(for: document, kind: kind, access: access)
    }

    func renameFolder(id: UUID, name: String) async -> Bool {
        guard mutationsEnabled,
              !activeOperations.contains(.renamingFolder),
              securityConversionTasks[id] == nil else { return false }
        let submittedName = LibraryTextNormalizer.ownedCopy(name)
        activeOperations.insert(.renamingFolder)
        defer { activeOperations.remove(.renamingFolder) }

        do {
            try await repository.renameFolder(id: id, name: submittedName)
            try await refreshAll()
            activeError = nil
            AccessibilityNotification.announce("Folder renamed")
            return true
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func moveDocuments(ids: Set<UUID>, to folderID: UUID?) async -> Bool {
        guard mutationsEnabled, !ids.isEmpty, !activeOperations.contains(.movingDocuments) else { return false }
        let sourceFolderIDs = Set(allDocuments.filter { ids.contains($0.id) }.compactMap(\.folderID))
        guard sourceFolderIDs.allSatisfy({ securityConversionTasks[$0] == nil }),
              folderID.map({ securityConversionTasks[$0] == nil }) ?? true else { return false }
        activeOperations.insert(.movingDocuments)
        defer { activeOperations.remove(.movingDocuments) }

        do {
            if let folderID,
               let destination = allFolders.first(where: { $0.id == folderID })?.folder,
               destination.isSecure {
                guard requirePro(.secureFolder) else { return false }
                guard let securityCoordinator else { throw LibraryRepositoryError.invalidSecurityState }
                let documents = allDocuments.filter { ids.contains($0.id) }
                guard documents.count == ids.count else { throw LibraryRepositoryError.missingDocument }
                let access = try await vaultAccess(folderID: folderID, reason: "Move documents into secure folder")
                secureSessions.begin(access)
                try await securityCoordinator.moveNormalDocumentsToSecure(
                    documents,
                    destination: destination,
                    access: access
                )
                lockSecureFolder(id: folderID)
            } else {
                try await repository.moveDocuments(ids: ids, to: folderID)
            }
            try await refreshAll()
            activeError = nil
            AccessibilityNotification.announce(ids.count == 1 ? "Document moved" : "Documents moved")
            return true
        } catch {
            if let folderID { lockSecureFolder(id: folderID) }
            if error as? VaultAuthenticationError == .cancelled { return false }
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func deleteFolder(id: UUID, mode: FolderDeletionMode) async -> Bool {
        guard mutationsEnabled,
              !activeOperations.contains(.deletingFolder),
              securityConversionTasks[id] == nil else { return false }
        activeOperations.insert(.deletingFolder)
        defer { activeOperations.remove(.deletingFolder) }

        do {
            if let summary = allFolders.first(where: { $0.id == id }), summary.folder.isSecure {
                guard let securityCoordinator, let securityRepository else {
                    throw LibraryRepositoryError.invalidSecurityState
                }
                let access = try await vaultAccess(folderID: id, reason: "Delete secure folder")
                secureSessions.begin(access)
                switch mode {
                case .keepDocuments:
                    try await securityCoordinator.convertFolder(id: id, to: .standard, access: access)
                    try await repository.deleteFolder(id: id, mode: .keepDocuments)
                case .deleteDocuments:
                    let snapshot = try await securityRepository.securitySnapshot(folderID: id)
                    try await securityCoordinator.deleteSecureFolderAndDocuments(
                        folder: summary.folder,
                        documents: snapshot.documents.map(\.document),
                        access: access
                    )
                }
                lockSecureFolder(id: id)
            } else {
                try await repository.deleteFolder(id: id, mode: mode)
            }
            try await refreshAll()
            activeError = nil
            AccessibilityNotification.announce("Folder deleted")
            return true
        } catch {
            lockSecureFolder(id: id)
            if error as? VaultAuthenticationError == .cancelled { return false }
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func queryDocuments(scope: DocumentScope, query: String) async throws -> [ScannedDocument] {
        try await repository.fetchDocuments(scope: scope, query: query, sort: sortOrder)
    }

    func ensureSearchablePDFIfNeeded(for document: ScannedDocument) async -> Bool {
        await store.ensureSearchablePDFIfNeeded(for: document)
    }

    func commonFolderID(for ids: Set<UUID>) -> UUID?? {
        let locations = Set(allDocuments.filter { ids.contains($0.id) }.map(\.folderID))
        guard locations.count == 1 else { return nil }
        return locations.first
    }

    func folderNameValidationMessage(_ name: String, excluding id: UUID? = nil) -> String? {
        do {
            let value = try LibraryTextNormalizer.validatedFolderName(name)
            if allFolders.contains(where: { $0.id != id && $0.folder.normalizedName == value.normalized }) {
                return LibraryRepositoryError.duplicateFolderName.localizedDescription
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func consumeActiveErrorMessage() -> String? {
        let message = activeError?.message
        activeError = nil
        return message
    }

    private func requirePro(_ feature: ProFeature) -> Bool {
        guard proAccess.hasAccess(to: feature) else {
            activeError = LibraryError(message: LibraryRepositoryError.proAccessRequired.localizedDescription)
            return false
        }
        return true
    }

    private func refreshAll() async throws {
        documentSearchTask?.cancel()
        folderSearchTask?.cancel()
        isDocumentSearchPending = false
        isFolderSearchPending = false
        async let fetchedDocuments = repository.fetchDocuments(scope: .all, query: librarySearchQuery, sort: sortOrder)
        async let fetchedAllDocuments = repository.fetchDocuments(scope: .all, query: "", sort: sortOrder)
        async let fetchedFolders = repository.fetchFolders(query: folderSearchQuery)
        async let fetchedAllFolders = repository.fetchFolders(query: "")
        documents = try await fetchedDocuments
        allDocuments = try await fetchedAllDocuments
        folders = try await fetchedFolders
        allFolders = try await fetchedAllFolders
        loadState = allDocuments.isEmpty && allFolders.isEmpty ? .empty : .loaded
    }

    private func scheduleDocumentSearch(immediate: Bool) {
        guard hasLoaded else { return }
        documentSearchTask?.cancel()
        isDocumentSearchPending = true
        let query = librarySearchQuery
        documentSearchTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled, let self else { return }
            do {
                let results = try await self.repository.fetchDocuments(scope: .all, query: query, sort: self.sortOrder)
                guard !Task.isCancelled else { return }
                self.documents = results
                self.isDocumentSearchPending = false
                self.loadState = self.allDocuments.isEmpty && self.allFolders.isEmpty ? .empty : .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.isDocumentSearchPending = false
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    private func scheduleFolderSearch(immediate: Bool) {
        guard hasLoaded else { return }
        folderSearchTask?.cancel()
        isFolderSearchPending = true
        let query = folderSearchQuery
        folderSearchTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled, let self else { return }
            do {
                let results = try await self.repository.fetchFolders(query: query)
                guard !Task.isCancelled else { return }
                self.folders = results
                self.isFolderSearchPending = false
                self.loadState = self.allDocuments.isEmpty && self.allFolders.isEmpty ? .empty : .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.isFolderSearchPending = false
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    static let preview: DocumentLibrary = {
        let repository = CoreDataLibraryRepository(inMemory: true)
        let library = DocumentLibrary(repository: repository)
        library.documents = [ScannedDocument.previewDocument]
        library.allDocuments = library.documents
        library.loadState = .loaded
        library.hasLoaded = true
        library.mutationsEnabled = true
        return library
    }()
}

@MainActor
final class FreeProAccessProvider: ProAccessProviding {
    var hasProAccess: Bool { false }
    func hasAccess(to feature: ProFeature) -> Bool { false }
}

struct LibraryError: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

private enum AccessibilityNotification {
    static func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
