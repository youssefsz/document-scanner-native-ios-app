import Foundation

nonisolated struct StoragePaths: Sendable {
    let rootDirectory: URL

    nonisolated var filesDirectory: URL {
        rootDirectory.appendingPathComponent("Files", isDirectory: true)
    }

    nonisolated var legacyMetadataURL: URL {
        rootDirectory.appendingPathComponent("library.json", isDirectory: false)
    }

    nonisolated var migrationBackupsDirectory: URL {
        rootDirectory.appendingPathComponent("MigrationBackups", isDirectory: true)
    }

    nonisolated var stagingDirectory: URL {
        rootDirectory.appendingPathComponent("Staging", isDirectory: true)
    }

    nonisolated var recoveryDirectory: URL {
        rootDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    nonisolated var vaultDirectory: URL {
        rootDirectory.appendingPathComponent("Vault", isDirectory: true)
    }

    nonisolated var sensitiveTemporaryDirectory: URL {
        rootDirectory.appendingPathComponent("SensitiveTemporary", isDirectory: true)
    }

    nonisolated var securityOperationsDirectory: URL {
        rootDirectory.appendingPathComponent("SecurityOperations", isDirectory: true)
    }

    nonisolated var sqliteURL: URL {
        rootDirectory.appendingPathComponent("Library.sqlite", isDirectory: false)
    }

    nonisolated static let production = StoragePaths(
        rootDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DocumentLibrary", isDirectory: true)
    )

    nonisolated func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: migrationBackupsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        try createProtectedDirectory(vaultDirectory, fileManager: fileManager)
        try createProtectedDirectory(sensitiveTemporaryDirectory, fileManager: fileManager)
        try createProtectedDirectory(securityOperationsDirectory, fileManager: fileManager)
    }


    private nonisolated func createProtectedDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }
}
