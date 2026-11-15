import SwiftUI
import UniformTypeIdentifiers

struct VaultRecoveryView: View {
    enum Mode {
        case settings
        case secureFolder
        case restore
    }

    var mode: Mode = .settings
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: DocumentLibrary
    @Environment(\.scenePhase) private var scenePhase

    @State private var backupURL: URL?
    @State private var displayedCode: String?
    @State private var archivedURL: URL?
    @State private var recoveryCode = ""
    @State private var savedCode = false
    @State private var showsImporter = false
    @State private var task: Task<Void, Never>?
    @State private var message: String?

    var body: some View {
        Form {
            if mode != .restore {
                transferSection
                backupSection
            }

            Section {
                Button("Choose Vault Backup") { showsImporter = true }
                    .disabled(task != nil)
                if let archivedURL {
                    Text(archivedURL.lastPathComponent)
                        .lineLimit(1)
                    SecureField("Recovery code", text: $recoveryCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Verify and Restore") { restore(archivedURL) }
                        .disabled(task != nil || recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Restore")
            } footer: {
                if mode == .restore {
                    Text("Choose the file you exported and enter its recovery code. Your existing documents will stay in place.")
                } else {
                    Text("Restore recovers the key for documents already on this device. If there is no vault, it imports the backup’s folders and documents.")
                }
            }

            if task != nil {
                ProgressView("Working with encrypted vault…")
            }
            if let message {
                Section { Text(message) }
            }
        }
        .navigationTitle(mode == .restore ? "Restore Vault Backup" : "Vault Transfer & Backup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode != .settings {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .privacySensitive()
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                archivedURL = url
                recoveryCode = ""
                message = nil
            case .failure:
                message = "DocScanner couldn’t open the backup you selected."
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                task?.cancel()
                recoveryCode = ""
                // Preserve an actively shared file, but hide the code as soon as
                // DocScanner leaves the foreground.
                if savedCode { displayedCode = nil } else { clearBackup() }
            }
        }
        .onDisappear {
            task?.cancel()
            recoveryCode = ""
            clearBackup()
        }
        .overlay {
            if scenePhase != .active {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
    }

    private var transferSection: some View {
        Section("Vault Transfer") {
            switch library.vaultTransferStatus {
            case .ready:
                Label("Ready for transfer", systemImage: "checkmark.shield")
            case .pending(let error):
                Label("Transfer setup incomplete", systemImage: "exclamationmark.shield")
                Text(error.localizedDescription)
                Text("You can make a backup now. Reopen a secure folder and unlock it again to retry transfer setup.")
                    .foregroundStyle(.secondary)
            case nil:
                Text("Open a secure folder and authenticate to check or complete transfer setup.")
            }
        }
    }

    private var backupSection: some View {
        Section {
            Button("Create Encrypted Backup") { makeBackup() }
                .disabled(task != nil || !library.allFolders.contains(where: { $0.folder.isSecure }))
            if let displayedCode {
                Text("Save this recovery code separately from the backup. DocScanner cannot recover it for you.")
                Text(displayedCode)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .privacySensitive()
                Button("I Saved the Recovery Code") {
                    savedCode = true
                    self.displayedCode = nil
                }
                .accessibilityIdentifier("vault-backup-code-saved")
            }
            if savedCode, let backupURL {
                ShareLink(item: backupURL) {
                    Label("Export Backup to Files", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("vault-backup-export")
            }
        } header: {
            Text("Encrypted Backup")
        } footer: {
            Text("The backup contains all secure folders and documents. Choose Save to Files when exporting.")
        }
    }

    private func makeBackup() {
        clearBackup()
        run {
            let result = try await library.makeVaultBackup()
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent())
            } else {
                backupURL = result.url
                displayedCode = result.recoveryCode
            }
        }
    }

    private func restore(_ url: URL) {
        let code = recoveryCode
        recoveryCode = ""
        run {
            switch try await library.restoreVault(from: url, code: code) {
            case .existingVaultUnlocked:
                message = "Vault key restored. Open a secure folder and unlock it to view your documents."
            case .backupImported:
                message = "Vault restored. Open your secure folders to view the imported documents."
            }
            archivedURL = nil
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        message = nil
        task = Task { @MainActor in
            defer { task = nil }
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                if (error as? VaultAuthenticationError) == .cancelled { return }
                // Foundation errors can contain paths or filenames.
                message = (error as? VaultAuthenticationError)?.errorDescription
                    ?? (error as? VaultBackupError)?.errorDescription
                    ?? VaultBackupError.storage.errorDescription
            }
        }
    }

    private func clearBackup() {
        if let backupURL { try? FileManager.default.removeItem(at: backupURL.deletingLastPathComponent()) }
        backupURL = nil
        displayedCode = nil
        savedCode = false
    }
}
