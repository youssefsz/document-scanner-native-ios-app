import Foundation

nonisolated struct SecurityDocumentRecord: Sendable {
    let document: ScannedDocument
    let secureTitleBlob: Data?
}

nonisolated struct FolderSecuritySnapshot: Sendable {
    let folder: DocumentFolder
    let documents: [SecurityDocumentRecord]
}

nonisolated struct SecurityMetadataChange: Codable, Sendable {
    let documentID: UUID
    let title: String
    let pdfFilename: String
    let previewFilename: String
    let protection: DocumentProtection
    let protectionFormatVersion: Int16
    let secureTitleBlob: Data?
    let folderID: UUID?
}

nonisolated protocol DocumentSecurityRepository: LibraryRepository {
    func securitySnapshot(folderID: UUID) async throws -> FolderSecuritySnapshot
    func commitSecurityChanges(
        folderID: UUID,
        targetSecurity: FolderSecurity,
        changes: [SecurityMetadataChange]
    ) async throws
    func securityCommitMatches(
        folderID: UUID,
        targetSecurity: FolderSecurity,
        changes: [SecurityMetadataChange]
    ) async throws -> Bool
    func renameSecureDocument(id: UUID, folderID: UUID, secureTitleBlob: Data) async throws
    func deleteSecureDocumentMetadata(ids: Set<UUID>, folderID: UUID) async throws
    func secureDocumentMetadataExists(ids: Set<UUID>) async throws -> Bool
    func deleteAuthenticatedSecureFolder(id: UUID) async throws
    func commitMovedSecurityChanges(_ changes: [SecurityMetadataChange], to folderID: UUID?) async throws
    func documentSecurityChangesMatch(_ changes: [SecurityMetadataChange]) async throws -> Bool
    func createSecureDocumentMetadata(
        _ change: SecurityMetadataChange,
        createdAt: Date,
        pageCount: Int
    ) async throws
}
