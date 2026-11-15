import Foundation

nonisolated struct VaultInventory: Sendable {
    let folders: [DocumentFolder]
    let documents: [SecurityDocumentRecord]

    var isEmpty: Bool { folders.isEmpty && documents.isEmpty }
}

nonisolated protocol VaultRecoveryRepository: Sendable {
    func vaultInventory() async throws -> VaultInventory
    func checkVaultImport(_ inventory: VaultInventory) async throws
    func importVault(_ inventory: VaultInventory) async throws
}
