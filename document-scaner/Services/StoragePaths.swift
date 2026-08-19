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
    }
}
