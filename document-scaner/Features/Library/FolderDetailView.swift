//
//  FolderDetailView.swift
//  document-scaner
//
//

import SwiftUI
import UIKit

struct FolderDetailView: View {
    let folder: DocumentFolder

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var library: DocumentLibrary
    @EnvironmentObject private var proStore: ProStore
    @State private var documents: [ScannedDocument] = []
    @State private var query = ""
    @State private var debouncedQuery = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDocument: ScannedDocument?
    @State private var showsRename = false
    @State private var showsDelete = false
    @State private var isDeleting = false
    @State private var displayName: String
    @State private var reloadToken = UUID()
    @State private var selectedDocumentIDs: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showsMove = false
    @State private var showsDocumentDeletion = false
    @State private var isDeletingDocuments = false
    @State private var showsAddDocuments = false
    @State private var isScannerPresented = false
    @State private var isPhotoImporterPresented = false
    @State private var photoImportProgress: PhotoImportProgress?
    @State private var isNamingPendingScan = false
    @State private var isSavingPendingScan = false
    @State private var pendingScanPages: [UIImage] = []
    @State private var pendingScanTitle = ""

    init(folder: DocumentFolder) {
        self.folder = folder
        _displayName = State(initialValue: folder.name)
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                if documents.isEmpty, isFolderSearchPending {
                    ProgressView(folderSearchLoadingTitle)
                        .padding(.top, 100)
                } else if let errorMessage {
                    AppUnavailableStateView(title: "Folder Unavailable", systemImage: "exclamationmark.triangle", description: errorMessage)
                        .padding(.horizontal, 24)
                        .padding(.top, 80)
                } else if documents.isEmpty {
                    AppUnavailableStateView(
                        title: query.isEmpty ? "Folder Is Empty" : "No Results",
                        systemImage: query.isEmpty ? "folder" : "magnifyingglass",
                        description: query.isEmpty ? "Move documents here from Library selection mode." : "No document titles match your search."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: folderColumns, spacing: 16) {
                        ForEach(documents) { document in
                            DocumentCard(
                                document: document,
                                isSelectionMode: isSelectionMode,
                                isSelected: selectedDocumentIDs.contains(document.id)
                            )
                                .frame(height: DocumentCardLayout.totalCardHeight)
                                .onTapGesture { handleTap(document) }
                                .onLongPressGesture(minimumDuration: 0.35) { beginSelection(document) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 120)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(folderSearchAnimation, value: documents.map(\.id))
        .animation(folderSearchAnimation, value: isFolderSearchPending)
        .navigationTitle(isSelectionMode ? "\(selectedDocumentIDs.count) Selected" : displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search document titles")
        .toolbar {
            if isSelectionMode {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { endSelection() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selectedDocumentIDs.count == documents.count ? "Deselect All" : "Select All") {
                        if selectedDocumentIDs.count == documents.count {
                            endSelection()
                        } else {
                            selectedDocumentIDs = Set(documents.map(\.id))
                        }
                    }
                }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Scan into Folder", systemImage: "document.viewfinder") {
                            openScanner()
                        }
                        Button("Import Photos", systemImage: "photo.on.rectangle") {
                            isPhotoImporterPresented = true
                        }
                        Button("Add Existing Documents", systemImage: "doc.badge.plus") {
                            showsAddDocuments = true
                        }
                        Divider()
                        Button("Rename", systemImage: "pencil") { showsRename = true }
                        Button("Delete Folder", systemImage: "trash", role: .destructive) { showsDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Folder Actions")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if isSelectionMode {
                LibrarySelectionBar(
                    selectionCount: selectedDocumentIDs.count,
                    isDeleting: isDeletingDocuments,
                    isMoving: library.activeOperations.contains(.movingDocuments),
                    moveAction: { showsMove = true },
                    deleteAction: { showsDocumentDeletion = true }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .overlay {
            if let photoImportProgress {
                PhotoImportProgressOverlay(progress: photoImportProgress)
            } else if isDeleting {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("Deleting folder…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
        .task(id: query) {
            await updateDebouncedFolderQuery()
        }
        .task(id: FolderDetailRequest(folderID: folder.id, query: debouncedQuery, reloadToken: reloadToken)) {
            await loadDocuments(query: debouncedQuery)
        }
        .onChange(of: library.allDocuments) { _ in reloadToken = UUID() }
        .fullScreenCover(item: $selectedDocument) { document in
            DocumentDetailView(document: document).environmentObject(library)
        }
        .documentPhotoImporter(
            isPresented: $isPhotoImporterPresented,
            progress: $photoImportProgress,
            onComplete: preparePendingScan,
            onError: { error in
                library.activeError = LibraryError(message: error.localizedDescription)
            }
        )
        .sheet(isPresented: $isScannerPresented) {
            DocumentScannerSheet(
                onComplete: { pages in
                    isScannerPresented = false
                    preparePendingScan(pages: pages)
                },
                onCancel: {
                    isScannerPresented = false
                },
                onError: { error in
                    isScannerPresented = false
                    library.activeError = LibraryError(message: error.localizedDescription)
                }
            )
            .ignoresSafeArea()
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $isNamingPendingScan) {
            DocumentTitleEditorSheet(
                title: "Name Document",
                message: "Choose a title before saving this document to “\(displayName)”.",
                saveButtonTitle: "Save to Folder",
                cancelButtonTitle: "Discard",
                isSaving: isSavingPendingScan,
                allowsInteractiveDismiss: false,
                documentTitle: $pendingScanTitle,
                onCancel: discardPendingScan,
                onSave: savePendingScan
            )
        }
        .sheet(isPresented: $showsAddDocuments) {
            AddDocumentsToFolderSheet(
                documents: library.allDocuments.filter { $0.folderID != folder.id },
                folderName: displayName,
                folderNamesByID: Dictionary(
                    uniqueKeysWithValues: library.allFolders.map { ($0.id, $0.folder.name) }
                ),
                onAdd: addExistingDocuments
            )
        }
        .sheet(isPresented: $showsMove) {
            FolderPickerSheet(
                folders: library.allFolders.map(\.folder),
                commonFolderID: folder.id,
                hasCommonFolder: true,
                isMoving: library.activeOperations.contains(.movingDocuments),
                onCreateFolder: { name in
                    await library.createFolder(name: name) ? nil : library.consumeActiveErrorMessage()
                },
                onMove: moveSelection
            )
            .proPaywallHost(store: proStore)
        }
        .sheet(isPresented: $showsRename) {
            FolderNameSheet(
                title: "Rename Folder",
                actionTitle: "Save",
                initialName: displayName,
                validation: { library.folderNameValidationMessage($0, excluding: folder.id) },
                onSave: { name in
                    let success = await library.renameFolder(id: folder.id, name: name)
                    if success { displayName = name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    return success ? nil : library.consumeActiveErrorMessage()
                }
            )
        }
        .confirmationDialog("Delete “\(displayName)”?", isPresented: $showsDelete, titleVisibility: .visible) {
            Button("Keep Documents", role: .destructive) { deleteFolder(.keepDocuments) }
            Button("Delete Folder and Documents", role: .destructive) { deleteFolder(.deleteDocuments) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This folder contains \(documents.count) documents. You can keep them unfiled or delete them everywhere.")
        }
        .confirmationDialog(
            selectedDocumentIDs.count == 1 ? "Delete 1 document?" : "Delete \(selectedDocumentIDs.count) documents?",
            isPresented: $showsDocumentDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Documents", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected documents globally, including their PDFs and previews.")
        }
    }

    private var folderColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count)
    }

    private var isFolderSearchPending: Bool {
        isLoading || LibraryTextNormalizer.normalize(query) != LibraryTextNormalizer.normalize(debouncedQuery)
    }

    private var folderSearchLoadingTitle: String {
        LibraryTextNormalizer.normalize(query).isEmpty ? "Loading Documents…" : "Searching Documents…"
    }

    private var folderSearchAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    @MainActor
    private func updateDebouncedFolderQuery() async {
        let submittedQuery = LibraryTextNormalizer.ownedCopy(query)
        if LibraryTextNormalizer.normalize(submittedQuery).isEmpty {
            isLoading = documents.isEmpty
            withAnimation(folderSearchAnimation) {
                debouncedQuery = ""
            }
            return
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        isLoading = documents.isEmpty
        withAnimation(folderSearchAnimation) {
            debouncedQuery = submittedQuery
        }
    }

    private func loadDocuments(query submittedQuery: String) async {
        isLoading = documents.isEmpty
        do {
            let results = try await library.queryDocuments(scope: .folder(folder.id), query: submittedQuery)
            guard !Task.isCancelled else { return }
            documents = results
            errorMessage = nil
            selectedDocumentIDs.formIntersection(Set(documents.map(\.id)))
            if selectedDocumentIDs.isEmpty { isSelectionMode = false }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteFolder(_ mode: FolderDeletionMode) {
        Task {
            isDeleting = mode == .deleteDocuments && !documents.isEmpty
            let success = await library.deleteFolder(id: folder.id, mode: mode)
            isDeleting = false
            if success { dismiss() }
        }
    }

    private func openScanner() {
        guard DocumentScannerSheet.isSupported else {
            library.activeError = LibraryError(message: "Document scanning requires a physical iPhone or iPad with camera access.")
            return
        }

        isScannerPresented = true
    }

    private func preparePendingScan(pages: [UIImage]) {
        guard !pages.isEmpty else {
            library.activeError = LibraryError(message: DocumentStoreError.emptyScan.localizedDescription)
            return
        }

        pendingScanPages = pages
        pendingScanTitle = DocumentTitleFormatter.default(for: .now)

        Task { @MainActor in
            await Task.yield()
            isNamingPendingScan = true
        }
    }

    private func discardPendingScan() {
        clearPendingScan()
        isNamingPendingScan = false
    }

    private func savePendingScan() {
        let pages = pendingScanPages
        let title = pendingScanTitle
        guard !pages.isEmpty, !isSavingPendingScan else { return }

        isSavingPendingScan = true
        Task {
            await library.importScan(pages: pages, title: title, folderID: folder.id)
            isSavingPendingScan = false
            guard library.activeError == nil else { return }

            clearPendingScan()
            isNamingPendingScan = false
            reloadToken = UUID()
            Haptics.success()
        }
    }

    private func clearPendingScan() {
        pendingScanPages = []
        pendingScanTitle = ""
    }

    private func addExistingDocuments(_ identifiers: Set<UUID>) async -> String? {
        let success = await library.moveDocuments(ids: identifiers, to: folder.id)
        if success {
            reloadToken = UUID()
            Haptics.success()
            return nil
        }
        return library.consumeActiveErrorMessage()
    }

    private func handleTap(_ document: ScannedDocument) {
        if isSelectionMode {
            toggleSelection(document)
        } else {
            selectedDocument = document
        }
    }

    private func beginSelection(_ document: ScannedDocument) {
        guard !isSelectionMode else {
            toggleSelection(document)
            return
        }
        isSelectionMode = true
        selectedDocumentIDs = [document.id]
        Haptics.selectionChanged()
    }

    private func toggleSelection(_ document: ScannedDocument) {
        if selectedDocumentIDs.contains(document.id) {
            selectedDocumentIDs.remove(document.id)
        } else {
            selectedDocumentIDs.insert(document.id)
        }
        isSelectionMode = !selectedDocumentIDs.isEmpty
        Haptics.selectionChanged()
    }

    private func endSelection() {
        selectedDocumentIDs.removeAll()
        isSelectionMode = false
    }

    private func moveSelection(to destination: UUID?) {
        let identifiers = selectedDocumentIDs
        Task {
            if await library.moveDocuments(ids: identifiers, to: destination) {
                showsMove = false
                endSelection()
                reloadToken = UUID()
            }
        }
    }

    private func deleteSelection() {
        let selected = documents.filter { selectedDocumentIDs.contains($0.id) }
        Task {
            isDeletingDocuments = true
            await library.delete(selected)
            isDeletingDocuments = false
            if library.activeError == nil {
                endSelection()
                reloadToken = UUID()
            }
        }
    }
}

private struct FolderDetailRequest: Equatable {
    let folderID: UUID
    let query: String
    let reloadToken: UUID
}
