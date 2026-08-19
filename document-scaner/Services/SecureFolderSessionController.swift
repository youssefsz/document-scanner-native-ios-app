import Combine
import Foundation

/// Owns the memory-only authorization capabilities for secure navigation flows.
/// It deliberately exposes only folder lock state and scoped capability lookup.
@MainActor
final class SecureFolderSessionController: ObservableObject {
    @Published private(set) var unlockedFolderIDs: Set<UUID> = []

    private var accessByFolder: [UUID: VaultAccess] = [:]

    func access(for folderID: UUID) -> VaultAccess? {
        guard let access = accessByFolder[folderID], access.isValid else {
            invalidate(folderID: folderID)
            return nil
        }
        return access
    }

    func begin(_ access: VaultAccess) {
        accessByFolder.removeValue(forKey: access.folderID)?.invalidate()
        accessByFolder[access.folderID] = access
        unlockedFolderIDs.insert(access.folderID)
    }

    func invalidate(folderID: UUID) {
        accessByFolder.removeValue(forKey: folderID)?.invalidate()
        unlockedFolderIDs.remove(folderID)
    }

    func invalidateAll() {
        accessByFolder.values.forEach { $0.invalidate() }
        accessByFolder.removeAll()
        unlockedFolderIDs.removeAll()
    }
}
