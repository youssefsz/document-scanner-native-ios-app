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
    @Published var activeError: LibraryError?
    @Published var selectedSection: LibrarySection = .library
    @Published var librarySearchQuery = ""
    @Published var folderSearchQuery = ""

    private let repository: any LibraryRepository
    private let store: DocumentStore
    private var hasLoaded = false
    private var sortOrder: LibrarySortOrder = .newestFirst
    private var documentSearchTask: Task<Void, Never>?
    private var folderSearchTask: Task<Void, Never>?

    var isLoading: Bool {
        switch loadState {
        case .initialLoading, .migrating:
            true
        default:
            false
        }
    }

    init(repository: (any LibraryRepository)? = nil, store: DocumentStore? = nil) {
        let resolvedRepository = repository ?? CoreDataLibraryRepository()
        self.repository = resolvedRepository
        self.store = store ?? DocumentStore(repository: resolvedRepository)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        loadState = .initialLoading
        activeError = nil

        do {
            if try await repository.needsLegacyMigration() {
                loadState = .migrating
            }
            try await repository.bootstrap()
            mutationsEnabled = true
            hasLoaded = true
            try await refreshAll()
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
        scheduleDocumentSearch(immediate: false)
    }

    func updateFolderSearch(_ query: String) {
        folderSearchQuery = query
        scheduleFolderSearch(immediate: false)
    }

    func importScan(
        pages: [UIImage],
        title: String? = nil,
        folderID: UUID? = nil
    ) async {
        guard mutationsEnabled, !activeOperations.contains(.savingScan) else { return }
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

    func createFolder(name: String) async -> Bool {
        guard mutationsEnabled, !activeOperations.contains(.creatingFolder) else { return false }
        let submittedName = LibraryTextNormalizer.ownedCopy(name)
        activeOperations.insert(.creatingFolder)
        defer { activeOperations.remove(.creatingFolder) }

        do {
            _ = try await repository.createFolder(name: submittedName)
            try await refreshAll()
            activeError = nil
            AccessibilityNotification.announce("Folder created")
            return true
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func renameFolder(id: UUID, name: String) async -> Bool {
        guard mutationsEnabled, !activeOperations.contains(.renamingFolder) else { return false }
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
        activeOperations.insert(.movingDocuments)
        defer { activeOperations.remove(.movingDocuments) }

        do {
            try await repository.moveDocuments(ids: ids, to: folderID)
            try await refreshAll()
            activeError = nil
            AccessibilityNotification.announce(ids.count == 1 ? "Document moved" : "Documents moved")
            return true
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    func deleteFolder(id: UUID, mode: FolderDeletionMode) async -> Bool {
        guard mutationsEnabled, !activeOperations.contains(.deletingFolder) else { return false }
        activeOperations.insert(.deletingFolder)
        defer { activeOperations.remove(.deletingFolder) }

        do {
            try await repository.deleteFolder(id: id, mode: mode)
            try await refreshAll()
            activeError = nil
            AccessibilityNotification.announce("Folder deleted")
            return true
        } catch {
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

    private func refreshAll() async throws {
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
        let query = librarySearchQuery
        documentSearchTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled, let self else { return }
            do {
                self.documents = try await self.repository.fetchDocuments(scope: .all, query: query, sort: self.sortOrder)
                self.loadState = self.allDocuments.isEmpty && self.allFolders.isEmpty ? .empty : .loaded
            } catch {
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    private func scheduleFolderSearch(immediate: Bool) {
        guard hasLoaded else { return }
        folderSearchTask?.cancel()
        let query = folderSearchQuery
        folderSearchTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled, let self else { return }
            do {
                self.folders = try await self.repository.fetchFolders(query: query)
                self.loadState = self.allDocuments.isEmpty && self.allFolders.isEmpty ? .empty : .loaded
            } catch {
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

struct LibraryError: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

private enum AccessibilityNotification {
    static func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
