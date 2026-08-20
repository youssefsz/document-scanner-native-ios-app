//
//  FolderManagementSheets.swift
//  document-scaner
//
//

import SwiftUI

struct NewFolderSheet: View {
    let validation: @MainActor (String) -> String?
    let onSave: @MainActor (String, FolderSecurity) async -> (success: Bool, error: String?)

    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestProFeature) private var requestProFeature
    @FocusState private var isFocused: Bool
    @State private var name = ""
    @State private var isSecure = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showsLearnMore = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Folder Name", text: $name)
                        .focused($isFocused)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { isSecure },
                        set: { newValue in
                            if !newValue {
                                isSecure = false
                            } else {
                                requestProFeature(.secureFolder) { isSecure = true }
                            }
                        }
                    )) {
                        Label("Secure Folder", systemImage: "lock.fill")
                    }
                    .disabled(isSaving)

                    if isSecure {
                        Button("Learn More") { showsLearnMore = true }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Use Face ID, Touch ID, or the device passcode to open this folder. Its documents are encrypted on this device.")
                }

                if let message = saveError ?? validation(name), !message.isEmpty, !name.isEmpty {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            AppToolbarProgressView(accessibilityLabel: "Creating folder")
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(validation(name) != nil || isSaving)
                }
            }
            .alert("About Secure Folders", isPresented: $showsLearnMore) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Secure folders are protected on this device. Keep another copy of important documents. If the app is deleted or the device is lost without a backup, these documents may not be recoverable.")
            }
        }
        .interactiveDismissDisabled(isSaving)
        .task {
            isSecure = false
            isFocused = true
        }
        .onChange(of: name) { _ in saveError = nil }
    }

    private func save() {
        let submittedName = LibraryTextNormalizer.ownedCopy(name)
        let security: FolderSecurity = isSecure ? .secure : .standard
        guard validation(submittedName) == nil, !isSaving else { return }
        isSaving = true
        Task { @MainActor [submittedName, security] in
            let result = await onSave(submittedName, security)
            isSaving = false
            saveError = result.error
            if result.success { dismiss() }
        }
    }
}

struct FolderSecurityChangeRequest: Identifiable {
    let folder: DocumentFolder
    let documentCount: Int
    let target: FolderSecurity

    var id: String { "\(folder.id.uuidString)-\(target.rawValue)" }
}

struct FolderSecurityChangeSheet: View {
    let request: FolderSecurityChangeRequest
    let progress: SecurityConversionProgress?
    let onCancel: () -> Void
    let onConfirm: @MainActor () async -> Bool

    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Folder", value: request.folder.name)
                    LabeledContent("Documents", value: "\(request.documentCount)")
                }

                Section {
                    if let progress {
                        ProgressView(
                            value: Double(progress.completedDocuments),
                            total: Double(max(progress.totalDocuments, 1))
                        )
                        Text(progressLabel(progress))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(explanation)
                    }
                }
            }
            .navigationTitle(request.target == .secure ? "Make Secure" : "Remove Security")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isCriticalPhase)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.target == .secure ? "Make Secure" : "Remove Security", action: confirm)
                        .disabled(isWorking)
                }
            }
        }
        .interactiveDismissDisabled(isCriticalPhase)
    }

    private var explanation: String {
        if request.target == .secure {
            return "The app will encrypt every PDF, preview, and document title in this folder."
        }
        return "Documents will stay in this folder and become available without authentication."
    }

    private var isCriticalPhase: Bool {
        guard let phase = progress?.phase else { return false }
        return [.preservingOriginals, .installing, .committingMetadata, .cleaningUp].contains(phase)
    }

    private func progressLabel(_ progress: SecurityConversionProgress) -> String {
        "\(progress.phase.label) \(progress.completedDocuments) of \(progress.totalDocuments) documents"
    }

    private func confirm() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            let success = await onConfirm()
            isWorking = false
            if success { onCancel() }
        }
    }
}

private extension SecurityConversionPhase {
    var label: String {
        switch self {
        case .staging: "Preparing"
        case .verifying: "Verifying"
        case .preservingOriginals: "Preserving originals"
        case .installing: "Installing files"
        case .committingMetadata: "Updating library"
        case .cleaningUp: "Cleaning up"
        }
    }
}

struct FolderNameSheet: View {
    let title: String
    let actionTitle: String
    let validation: @MainActor (String) -> String?
    let onSave: @MainActor (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var name: String
    @State private var saveError: String?
    @State private var isSaving = false

    init(
        title: String,
        actionTitle: String,
        initialName: String,
        validation: @escaping @MainActor (String) -> String?,
        onSave: @escaping @MainActor (String) async -> String?
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.validation = validation
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Folder Name", text: $name)
                        .focused($isFocused)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }

                if let message = saveError ?? validation(name), !name.isEmpty {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            AppToolbarProgressView(accessibilityLabel: "Saving folder")
                        } else {
                            Text(actionTitle)
                        }
                    }
                    .disabled(validation(name) != nil)
                    .accessibilityLabel(isSaving ? "Saving folder" : actionTitle)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .task { isFocused = true }
        .onChange(of: name) { _ in saveError = nil }
    }

    private func save() {
        // Never read the TextField's @State-backed storage after suspension. SwiftUI
        // may replace the view value while the async operation is in flight.
        let submittedName = LibraryTextNormalizer.ownedCopy(name)
        guard validation(submittedName) == nil, !isSaving else { return }
        isSaving = true
        Task { @MainActor [submittedName] in
            saveError = await onSave(submittedName)
            isSaving = false
            if saveError == nil { dismiss() }
        }
    }
}

struct FolderPickerSheet: View {
    let folders: [DocumentFolder]
    let commonFolderID: UUID?
    let hasCommonFolder: Bool
    let isMoving: Bool
    let onCreateFolder: @MainActor (String) async -> String?
    let onMove: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestProFeature) private var requestProFeature
    @State private var showsNewFolder = false
    @State private var pendingSecureDestination: DocumentFolder?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    destinationRow(name: "Unfiled", systemImage: "tray", id: nil)
                }

                Section("Folders") {
                    ForEach(folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
                        destinationRow(
                            name: folder.name,
                            systemImage: folder.isSecure ? "lock.fill" : "folder",
                            id: folder.id,
                            isSecure: folder.isSecure
                        )
                    }
                    Button {
                        showsNewFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                }
            }
            .navigationTitle("Move Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isMoving)
                }
            }
        }
        .interactiveDismissDisabled(isMoving)
        .confirmationDialog(
            "Move and Secure?",
            isPresented: Binding(
                get: { pendingSecureDestination != nil },
                set: { if !$0 { pendingSecureDestination = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move and Secure") {
                guard let destination = pendingSecureDestination else { return }
                pendingSecureDestination = nil
                onMove(destination.id)
            }
            Button("Cancel", role: .cancel) { pendingSecureDestination = nil }
        } message: {
            Text("The selected documents will be encrypted and moved into \(pendingSecureDestination?.name ?? "the secure folder").")
        }
        .sheet(isPresented: $showsNewFolder) {
            FolderNameSheet(
                title: "New Folder",
                actionTitle: "Create",
                initialName: "",
                validation: { name in
                    do {
                        let value = try LibraryTextNormalizer.validatedFolderName(name)
                        return folders.contains(where: { $0.normalizedName == value.normalized })
                            ? LibraryRepositoryError.duplicateFolderName.localizedDescription
                            : nil
                    } catch {
                        return error.localizedDescription
                    }
                },
                onSave: onCreateFolder
            )
        }
    }

    private func destinationRow(
        name: String,
        systemImage: String,
        id: UUID?,
        isSecure: Bool = false
    ) -> some View {
        Button {
            if isSecure, let id, let folder = folders.first(where: { $0.id == id }) {
                requestProFeature(.secureFolder) {
                    pendingSecureDestination = folder
                }
            } else {
                onMove(id)
            }
        } label: {
            HStack {
                Label(name, systemImage: systemImage)
                Spacer()
                if hasCommonFolder, commonFolderID == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(isMoving || (hasCommonFolder && commonFolderID == id))
        .accessibilityValue(hasCommonFolder && commonFolderID == id ? "Current location" : "")
    }
}

struct AddDocumentsToFolderSheet: View {
    let documents: [ScannedDocument]
    let folderName: String
    let folderNamesByID: [UUID: String]
    let onAdd: @MainActor (Set<UUID>) async -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var selectedDocumentIDs: Set<UUID> = []
    @State private var isAdding = false
    @State private var addError: String?

    var body: some View {
        NavigationStack {
            Group {
                if documents.isEmpty {
                    AppUnavailableStateView(
                        title: "Everything Is Already Here",
                        systemImage: "folder.badge.checkmark",
                        description: "There are no other documents available to add to this folder."
                    )
                    .padding(.horizontal, 24)
                } else if isSearchPending, filteredDocuments.isEmpty {
                    ProgressView("Searching Documents…")
                        .controlSize(.regular)
                        .transition(.opacity)
                } else if filteredDocuments.isEmpty {
                    AppUnavailableStateView(
                        title: "No Results",
                        systemImage: "magnifyingglass",
                        description: "No document titles match your search."
                    )
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                } else {
                    List(filteredDocuments) { document in
                        documentRow(document)
                    }
                    .listStyle(.insetGrouped)
                    .transition(.opacity)
                }
            }
            .navigationTitle("Add to \(folderName)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search document titles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isAdding)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: addSelection) {
                        if isAdding {
                            AppToolbarProgressView(accessibilityLabel: "Adding documents")
                        } else {
                            Text(addButtonTitle)
                        }
                    }
                    .disabled(selectedDocumentIDs.isEmpty)
                    .accessibilityLabel(isAdding ? "Adding documents" : addButtonTitle)
                }
            }
        }
        .interactiveDismissDisabled(isAdding)
        .task(id: query) {
            await updateDebouncedQuery()
        }
        .alert("Couldn’t Add Documents", isPresented: addErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "Unknown error")
        }
    }

    private var filteredDocuments: [ScannedDocument] {
        let normalizedQuery = LibraryTextNormalizer.normalize(debouncedQuery)
        guard !normalizedQuery.isEmpty else { return documents }
        return documents.filter {
            LibraryTextNormalizer.normalize($0.title).contains(normalizedQuery)
        }
    }

    private var isSearchPending: Bool {
        LibraryTextNormalizer.normalize(query) != LibraryTextNormalizer.normalize(debouncedQuery)
    }

    @MainActor
    private func updateDebouncedQuery() async {
        let submittedQuery = LibraryTextNormalizer.ownedCopy(query)
        if LibraryTextNormalizer.normalize(submittedQuery).isEmpty {
            withAnimation(searchAnimation) {
                debouncedQuery = ""
            }
            return
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(searchAnimation) {
            debouncedQuery = submittedQuery
        }
    }

    private var searchAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private var addButtonTitle: String {
        selectedDocumentIDs.isEmpty ? "Add" : "Add (\(selectedDocumentIDs.count))"
    }

    private var addErrorBinding: Binding<Bool> {
        Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )
    }

    private func documentRow(_ document: ScannedDocument) -> some View {
        let isSelected = selectedDocumentIDs.contains(document.id)

        return Button {
            if isSelected {
                selectedDocumentIDs.remove(document.id)
            } else {
                selectedDocumentIDs.insert(document.id)
            }
            Haptics.selectionChanged()
        } label: {
            HStack(spacing: 14) {
                DocumentThumbnail(url: document.previewURL)
                    .frame(width: 48, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(documentLocation(document))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(document.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Double tap to toggle selection")
    }

    private func documentLocation(_ document: ScannedDocument) -> String {
        guard let folderID = document.folderID else { return "Unfiled" }
        return folderNamesByID[folderID].map { "In \($0)" } ?? "In another folder"
    }

    private func addSelection() {
        let identifiers = selectedDocumentIDs
        guard !identifiers.isEmpty, !isAdding else { return }

        isAdding = true
        Task { @MainActor [identifiers] in
            addError = await onAdd(identifiers)
            isAdding = false
            if addError == nil { dismiss() }
        }
    }
}
