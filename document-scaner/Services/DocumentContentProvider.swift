import Foundation

nonisolated protocol DocumentContentProviding: Sendable {
    func data(
        for document: ScannedDocument,
        kind: VaultAssetKind,
        access: VaultAccess?
    ) async throws -> Data
}

/// Supplies ordinary file content or decrypts vault content only when handed a
/// live folder-scoped capability. Views and export code never open vault URLs.
nonisolated struct DocumentContentProvider: DocumentContentProviding, Sendable {
    let paths: StoragePaths
    let crypto: VaultCryptoService

    init(paths: StoragePaths = .production, crypto: VaultCryptoService = VaultCryptoService()) {
        self.paths = paths
        self.crypto = crypto
    }

    func data(
        for document: ScannedDocument,
        kind: VaultAssetKind,
        access: VaultAccess?
    ) async throws -> Data {
        let url = kind == .pdf ? document.pdfURL(in: paths) : document.previewURL(in: paths)
        if !document.isSecure {
            return try await Task.detached {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
        }

        guard let access,
              access.isValid,
              document.folderID == access.folderID else {
            throw LibraryRepositoryError.secureAccessRequired
        }
        return try await Task.detached { [crypto, paths] in
            try crypto.decryptFileData(
                at: url,
                documentID: document.id,
                kind: kind,
                access: access,
                temporaryDirectory: paths.sensitiveTemporaryDirectory
            )
        }.value
    }
}
