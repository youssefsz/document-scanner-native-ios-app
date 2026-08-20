import Foundation

nonisolated enum LibrarySection: String, CaseIterable, Identifiable, Sendable {
    case library = "Library"
    case folders = "Folders"

    var id: Self { self }
}

nonisolated struct DocumentFolder: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let normalizedName: String
    let createdAt: Date
    let updatedAt: Date
    let security: FolderSecurity

    nonisolated init(
        id: UUID,
        name: String,
        normalizedName: String,
        createdAt: Date,
        updatedAt: Date,
        security: FolderSecurity = .standard
    ) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.security = security
    }

    var isSecure: Bool { security == .secure }
}

nonisolated enum FolderSecurity: Int16, Codable, Hashable, Sendable {
    case standard = 0
    case secure = 1
}

nonisolated enum DocumentProtection: Int16, Codable, Hashable, Sendable {
    case standard = 0
    case vaultV1 = 1
}

nonisolated enum VaultAssetKind: UInt8, Codable, Hashable, Sendable {
    case pdf = 1
    case preview = 2
    case title = 3
}

nonisolated struct FolderSummary: Identifiable, Hashable, Sendable {
    let folder: DocumentFolder
    let documentCount: Int
    let newestDocuments: [ScannedDocument]

    var id: UUID { folder.id }
}

nonisolated enum DocumentScope: Hashable, Sendable {
    case all
    case unfiled
    case folder(UUID)
}

nonisolated enum LibraryLoadState: Equatable, Sendable {
    case initialLoading
    case migrating
    case loaded
    case empty
    case migrationFailed(String)
    case failed(String)
}

nonisolated enum LibrarySortOrder: Sendable {
    case newestFirst
    case oldestFirst
}

nonisolated enum FolderDeletionMode: Sendable {
    case keepDocuments
    case deleteDocuments
}

nonisolated enum LibraryOperation: Hashable, Sendable {
    case savingScan
    case deletingDocuments
    case creatingFolder
    case renamingFolder
    case movingDocuments
    case deletingFolder
    case changingFolderSecurity
}

nonisolated enum LibraryRepositoryError: LocalizedError, Equatable, Sendable {
    case invalidFolderName
    case folderNameTooLong
    case duplicateFolderName
    case missingFolder
    case missingDocument
    case missingFile(String)
    case migrationFailed(String)
    case storageFailed(String)
    case secureAccessRequired
    case proAccessRequired
    case invalidSecurityState

    var errorDescription: String? {
        switch self {
        case .invalidFolderName:
            "Folder names cannot be empty."
        case .folderNameTooLong:
            "Folder names must contain 80 characters or fewer."
        case .duplicateFolderName:
            "A folder with this name already exists."
        case .missingFolder:
            "The folder no longer exists."
        case .missingDocument:
            "The document no longer exists."
        case .missingFile(let filename):
            "The file \(filename) is missing from local storage."
        case .migrationFailed(let message):
            "The existing library could not be upgraded. \(message)"
        case .storageFailed(let message):
            message
        case .secureAccessRequired:
            "Unlock the secure folder to continue."
        case .proAccessRequired:
            "DocScanner Pro is required to create protected content."
        case .invalidSecurityState:
            "The document security state is inconsistent."
        }
    }
}

nonisolated enum LibraryTextNormalizer {
    /// Forces independently owned UTF-8 storage before a value crosses an async boundary.
    nonisolated static func ownedCopy(_ value: String) -> String {
        String(decoding: Array(value.utf8), as: UTF8.self)
    }

    nonisolated static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased(with: .current)
    }

    nonisolated static func validatedFolderName(_ value: String) throws -> (display: String, normalized: String) {
        let display = ownedCopy(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { throw LibraryRepositoryError.invalidFolderName }
        guard display.count <= 80 else { throw LibraryRepositoryError.folderNameTooLong }
        return (display, normalize(display))
    }
}
