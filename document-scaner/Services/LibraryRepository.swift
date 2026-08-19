import Foundation

nonisolated protocol LibraryRepository: Sendable {
    func needsLegacyMigration() async throws -> Bool
    func bootstrap() async throws
    func loadLegacyFallback() async -> [ScannedDocument]

    func fetchDocuments(scope: DocumentScope, query: String, sort: LibrarySortOrder) async throws -> [ScannedDocument]
    func fetchFolders(query: String) async throws -> [FolderSummary]

    func createDocument(_ document: ScannedDocument) async throws
    func renameDocument(id: UUID, title: String) async throws
    func deleteDocuments(ids: Set<UUID>) async throws

    func createFolder(name: String) async throws -> DocumentFolder
    func renameFolder(id: UUID, name: String) async throws
    func deleteFolder(id: UUID, mode: FolderDeletionMode) async throws
    func moveDocuments(ids: Set<UUID>, to folderID: UUID?) async throws
}
