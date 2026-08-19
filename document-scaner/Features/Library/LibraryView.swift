//
//  LibraryView.swift
//  document-scaner
//
//

import SwiftUI
import VisionKit
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var library: DocumentLibrary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @AppStorage(AppPreferenceKey.documentSortOrder) private var documentSortOrder = DocumentSortOrder.newestFirst.rawValue
    @AppStorage(AppPreferenceKey.hasCreatedFirstDocument) private var hasCreatedFirstDocument = false
    @State private var isScannerPresented = false
    @State private var isSavingPendingScan = false
    @State private var isDeletingSelection = false
    @State private var isNamingPendingScan = false
    @State private var isContentScrolled = false
    @State private var isSelectionMode = false
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingMoveSheet = false
    @State private var isShowingNewFolderSheet = false
    @State private var folderBeingRenamed: DocumentFolder?
    @State private var folderPendingDeletion: FolderSummary?
    @State private var isDeletingFolder = false
    @State private var pendingScanPages: [UIImage] = []
    @State private var pendingScanTitle = ""
    @State private var selectedDocument: ScannedDocument?
    @State private var selectedDocumentIDs: Set<ScannedDocument.ID> = []

    private let gridSpacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let usesSingleColumn = proxy.size.width < 350 || dynamicTypeSize.isAccessibilitySize
                let columnCount: CGFloat = usesSingleColumn ? 1 : 2
                let availableWidth = proxy.size.width - (horizontalPadding * 2) - (gridSpacing * (columnCount - 1))
                let cardWidth = max(1, floor(availableWidth / columnCount))
                let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing, alignment: .top), count: Int(columnCount))

                ScrollView {
                    VStack(spacing: 0) {
                        LibraryScrollPositionReader()
                        rootContent(cardWidth: cardWidth, columns: columns)
                    }
                }
                .coordinateSpace(name: LibraryScrollCoordinateSpace.name)
                .onPreferenceChange(LibraryScrollOffsetPreferenceKey.self) { offset in
                    isContentScrolled = offset < -1
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle(library.selectedSection.rawValue)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        toolbarPrincipal
                    }

                    if isSelectionMode {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Cancel") {
                                endSelectionMode()
                            }
                        }

                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(allDisplayedSelected ? "Deselect All" : "Select All") {
                                toggleSelectAll()
                            }
                            .disabled(displayedDocuments.isEmpty || isDeletingSelection)
                        }
                    } else {
                        if library.selectedSection == .folders, library.mutationsEnabled {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button {
                                    isShowingNewFolderSheet = true
                                } label: {
                                    Image(systemName: "folder.badge.plus")
                                }
                                .accessibilityLabel("New Folder")
                            }
                        }

                        ToolbarItem(placement: .navigationBarTrailing) {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel("Settings")
                        }
                    }
                }
                .appTopScrollEdgeEffect(isScrolled: isContentScrolled)
                .overlay(alignment: .bottom) {
                    bottomAccessory
                }
                .overlay {
                    if isDeletingSelection || isDeletingFolder {
                        deletionOverlay
                    }
                }
                .librarySearchable(enabled: library.mutationsEnabled, text: activeSearchText, prompt: searchPrompt)
                .navigationDestination(for: DocumentFolder.self) { folder in
                    FolderDetailView(folder: folder)
                        .environmentObject(library)
                }
            }
        }
        .animation(selectionAnimation, value: isSelectionMode)
        .animation(selectionAnimation, value: selectedDocumentIDs)
        .animation(bottomAccessoryAnimation, value: library.selectedSection)
        .task {
            library.updateSortOrder(rawValue: documentSortOrder)
            await library.loadIfNeeded()
        }
        .onChange(of: documentSortOrder) { value in
            library.updateSortOrder(rawValue: value)
        }
        .onChange(of: library.selectedSection) { section in
            if section == .folders { endSelectionMode() }
        }
        .onChange(of: library.documents) { documents in
            if !hasCreatedFirstDocument {
                AppReviewCoordinator.registerExistingLibraryIfNeeded(documents)
                hasCreatedFirstDocument = UserDefaults.standard.bool(forKey: AppPreferenceKey.hasCreatedFirstDocument)
            }
            pruneSelection(using: Set(documents.map(\.id)))
        }
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
                message: "Choose a title before saving this scan to your library.",
                saveButtonTitle: "Save Document",
                cancelButtonTitle: "Discard",
                isSaving: isSavingPendingScan,
                allowsInteractiveDismiss: false,
                documentTitle: $pendingScanTitle,
                onCancel: discardPendingScan,
                onSave: savePendingScan
            )
        }
        .sheet(isPresented: $isShowingNewFolderSheet) {
            FolderNameSheet(
                title: "New Folder",
                actionTitle: "Create",
                initialName: "",
                validation: { library.folderNameValidationMessage($0) },
                onSave: { name in
                    await library.createFolder(name: name) ? nil : library.consumeActiveErrorMessage()
                }
            )
        }
        .sheet(item: $folderBeingRenamed) { folder in
            FolderNameSheet(
                title: "Rename Folder",
                actionTitle: "Save",
                initialName: folder.name,
                validation: { library.folderNameValidationMessage($0, excluding: folder.id) },
                onSave: { name in
                    await library.renameFolder(id: folder.id, name: name) ? nil : library.consumeActiveErrorMessage()
                }
            )
        }
        .sheet(isPresented: $isShowingMoveSheet) {
            FolderPickerSheet(
                folders: library.allFolders.map(\.folder),
                commonFolderID: commonSelectionFolderID,
                hasCommonFolder: hasCommonSelectionFolder,
                isMoving: library.activeOperations.contains(.movingDocuments),
                onCreateFolder: { name in
                    await library.createFolder(name: name) ? nil : library.consumeActiveErrorMessage()
                },
                onMove: moveSelectedDocuments
            )
        }
        .fullScreenCover(item: $selectedDocument) { document in
            DocumentDetailView(document: document)
                .environmentObject(library)
        }
        .alert("Something Went Wrong", isPresented: activeErrorBinding) {
            Button("OK", role: .cancel) {
                library.activeError = nil
            }
        } message: {
            Text(library.activeError?.message ?? "Unknown error")
        }
        .confirmationDialog(deleteConfirmationTitle, isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button(deleteActionTitle, role: .destructive) {
                deleteSelectedDocuments()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage)
        }
        .confirmationDialog(
            folderDeletionTitle,
            isPresented: folderDeletionBinding,
            titleVisibility: .visible
        ) {
            Button("Keep Documents", role: .destructive) {
                deletePendingFolder(mode: .keepDocuments)
            }
            Button("Delete Folder and Documents", role: .destructive) {
                deletePendingFolder(mode: .deleteDocuments)
            }
            Button("Cancel", role: .cancel) {
                folderPendingDeletion = nil
            }
        } message: {
            Text(folderDeletionMessage)
        }
    }

    @ViewBuilder
    private func rootContent(cardWidth: CGFloat, columns: [GridItem]) -> some View {
        switch library.loadState {
        case .initialLoading:
            LibraryLoadingSkeletonView(cardWidth: cardWidth, spacing: gridSpacing)
        case .migrating:
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                Text("Upgrading Your Library…")
                    .font(.title3.weight(.semibold))
                Text("Your existing documents are being prepared. PDFs and previews will not be removed or changed.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Upgrading your library")
            .padding(.horizontal, 32)
            .padding(.top, 100)
        case .migrationFailed(let message):
            migrationFailureContent(message: message, columns: columns)
        case .failed(let message):
            recoverableState(
                title: "Library Unavailable",
                systemImage: "exclamationmark.triangle",
                message: message,
                retry: { Task { await library.reload() } }
            )
        case .loaded, .empty:
            if library.selectedSection == .library {
                documentRootContent(columns: columns)
            } else {
                folderRootContent(columns: columns)
            }
        }
    }

    @ViewBuilder
    private func documentRootContent(columns: [GridItem]) -> some View {
        if displayedDocuments.isEmpty {
            AppUnavailableStateView(
                title: library.librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Documents Yet" : "No Results",
                systemImage: library.librarySearchQuery.isEmpty ? "doc.viewfinder" : "magnifyingglass",
                description: library.librarySearchQuery.isEmpty
                    ? "Scan paper documents and the app will save them as PDFs in a local library."
                    : "No document titles match your search."
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.horizontal, 24)
        } else {
            LazyVGrid(columns: columns, alignment: .center, spacing: gridSpacing) {
                ForEach(displayedDocuments) { document in
                    LibraryDocumentTile(
                        document: document,
                        cardWidth: nil,
                        isSelectionMode: isSelectionMode,
                        isSelected: selectedDocumentIDs.contains(document.id),
                        onTap: { handlePrimaryAction(for: document) },
                        onLongPress: { handleLongPress(on: document) }
                    )
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, 140)
        }
    }

    private func migrationFailureContent(message: String, columns: [GridItem]) -> some View {
        VStack(spacing: 24) {
            recoverableState(
                title: "Library Upgrade Paused",
                systemImage: "externaldrive.badge.exclamationmark",
                message: message,
                retry: { Task { await library.retryMigration() } }
            )
            .padding(.top, 0)

            if !library.documents.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Existing Documents")
                        .font(.headline)
                    Text("You can still open your legacy library. Editing and folder actions stay disabled until the upgrade succeeds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        ForEach(library.documents) { document in
                            DocumentCard(document: document)
                                .frame(height: DocumentCardLayout.totalCardHeight)
                                .onTapGesture { selectedDocument = document }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 40)
            }
        }
    }

    @ViewBuilder
    private func folderRootContent(columns: [GridItem]) -> some View {
        if library.folders.isEmpty {
            VStack(spacing: 22) {
                AppUnavailableStateView(
                    title: library.folderSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Folders Yet" : "No Results",
                    systemImage: library.folderSearchQuery.isEmpty ? "folder" : "magnifyingglass",
                    description: library.folderSearchQuery.isEmpty
                        ? "Create a folder to organize documents without moving their saved files."
                        : "No folder names match your search."
                )

                if library.folderSearchQuery.isEmpty {
                    Button("New Folder") { isShowingNewFolderSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
            .padding(.horizontal, 24)
        } else {
            LazyVGrid(columns: columns, alignment: .center, spacing: gridSpacing) {
                ForEach(library.folders) { summary in
                    NavigationLink(value: summary.folder) {
                        FolderCard(summary: summary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            folderBeingRenamed = summary.folder
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            folderPendingDeletion = summary
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .accessibilityAction(named: "Rename") { folderBeingRenamed = summary.folder }
                    .accessibilityAction(named: "Delete") { folderPendingDeletion = summary }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, 140)
        }
    }

    private func recoverableState(
        title: String,
        systemImage: String,
        message: String,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 22) {
            AppUnavailableStateView(title: title, systemImage: systemImage, description: message)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 80)
    }

    @ViewBuilder
    private var toolbarPrincipal: some View {
        if isSelectionMode {
            Text(selectionTitle)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
        } else if library.mutationsEnabled {
            Picker("Library Section", selection: $library.selectedSection) {
                ForEach(LibrarySection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .accessibilityLabel("Library or Folders")
        } else {
            Text("Documents")
                .font(.headline.weight(.semibold))
        }
    }

    private var activeSearchText: Binding<String> {
        Binding(
            get: {
                library.selectedSection == .library ? library.librarySearchQuery : library.folderSearchQuery
            },
            set: { value in
                if library.selectedSection == .library {
                    library.updateLibrarySearch(value)
                } else {
                    library.updateFolderSearch(value)
                }
            }
        )
    }

    private var searchPrompt: String {
        library.selectedSection == .library ? "Search document titles" : "Search folder names"
    }

    private var emptyState: some View {
        AppUnavailableStateView(
            title: "No Documents Yet",
            systemImage: "doc.viewfinder",
            description: "Scan paper documents and the app will save them as PDFs in a local library."
        )
    }

    private var floatingScanButton: some View {
        Button {
            openScanner()
        } label: {
            Label("Scan Document", systemImage: "document.viewfinder")
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .appProminentButtonStyle()
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .transition(bottomAccessoryTransition)
    }

    @ViewBuilder
    private var bottomAccessory: some View {
        if library.mutationsEnabled, library.selectedSection == .library {
            if isSelectionMode {
                LibrarySelectionBar(
                    selectionCount: selectedDocumentIDs.count,
                    isDeleting: isDeletingSelection,
                    isMoving: library.activeOperations.contains(.movingDocuments),
                    moveAction: {
                        isShowingMoveSheet = true
                    },
                    deleteAction: {
                        isShowingDeleteConfirmation = true
                    }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .transition(bottomAccessoryTransition)
            } else {
                floatingScanButton
            }
        }
    }

    private var deletionOverlay: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            ProgressView(isDeletingFolder ? "Deleting folder..." : "Deleting documents...")
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .transition(.opacity)
    }

    private var commonSelectionFolderID: UUID? {
        library.commonFolderID(for: selectedDocumentIDs) ?? nil
    }

    private var hasCommonSelectionFolder: Bool {
        library.commonFolderID(for: selectedDocumentIDs) != nil
    }

    private func moveSelectedDocuments(to folderID: UUID?) {
        let identifiers = selectedDocumentIDs
        guard !identifiers.isEmpty else { return }
        Task {
            if await library.moveDocuments(ids: identifiers, to: folderID) {
                isShowingMoveSheet = false
                endSelectionMode()
                Haptics.success()
            }
        }
    }

    private var folderDeletionBinding: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { if !$0 { folderPendingDeletion = nil } }
        )
    }

    private var folderDeletionTitle: String {
        guard let summary = folderPendingDeletion else { return "Delete Folder?" }
        return "Delete “\(summary.folder.name)”?"
    }

    private var folderDeletionMessage: String {
        guard let summary = folderPendingDeletion else { return "" }
        let count = summary.documentCount
        return "This folder contains \(count) document\(count == 1 ? "" : "s"). You can keep them unfiled or delete them everywhere."
    }

    private func deletePendingFolder(mode: FolderDeletionMode) {
        guard let summary = folderPendingDeletion else { return }
        Task {
            isDeletingFolder = mode == .deleteDocuments && summary.documentCount > 0
            let succeeded = await library.deleteFolder(id: summary.id, mode: mode)
            isDeletingFolder = false
            if succeeded {
                folderPendingDeletion = nil
                Haptics.success()
            }
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
        let existingDocumentCount = library.allDocuments.count

        guard !pages.isEmpty, !isSavingPendingScan else { return }

        isSavingPendingScan = true

        Task {
            await library.importScan(pages: pages, title: title)
            isSavingPendingScan = false

            guard library.activeError == nil else { return }

            AppReviewCoordinator.armFirstDocumentReviewIfNeeded(
                existingDocumentCount: existingDocumentCount,
                updatedDocuments: library.documents
            )
            hasCreatedFirstDocument = UserDefaults.standard.bool(forKey: AppPreferenceKey.hasCreatedFirstDocument)

            clearPendingScan()
            isNamingPendingScan = false
            Haptics.success()
        }
    }

    private func clearPendingScan() {
        pendingScanPages = []
        pendingScanTitle = ""
    }

    private var activeErrorBinding: Binding<Bool> {
        Binding(
            get: { library.activeError != nil },
            set: { isPresented in
                if !isPresented {
                    library.activeError = nil
                }
            }
        )
    }

    private var selectionAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.84)
    }

    private var bottomAccessoryAnimation: Animation? {
        accessibilityReduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)
    }

    private var bottomAccessoryTransition: AnyTransition {
        .move(edge: .bottom)
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.96, anchor: .bottom))
    }

    private var selectionTitle: String {
        switch selectedDocumentIDs.count {
        case 0:
            "Select Documents"
        case 1:
            "1 Selected"
        default:
            "\(selectedDocumentIDs.count) Selected"
        }
    }

    private var deleteActionTitle: String {
        selectedDocumentIDs.count == 1 ? "Delete Document" : "Delete Documents"
    }

    private var deleteConfirmationTitle: String {
        selectedDocumentIDs.count == 1 ? "Delete 1 document?" : "Delete \(selectedDocumentIDs.count) documents?"
    }

    private var deleteConfirmationMessage: String {
        "This removes the selected PDFs and previews from local storage."
    }

    private var displayedDocuments: [ScannedDocument] {
        library.documents
    }

    private var selectedDocuments: [ScannedDocument] {
        displayedDocuments.filter { selectedDocumentIDs.contains($0.id) }
    }

    private var allDisplayedSelected: Bool {
        !displayedDocuments.isEmpty && displayedDocuments.allSatisfy { selectedDocumentIDs.contains($0.id) }
    }

    private func handlePrimaryAction(for document: ScannedDocument) {
        if isSelectionMode {
            toggleSelection(for: document)
        } else {
            selectedDocument = document
        }
    }

    private func handleLongPress(on document: ScannedDocument) {
        if isSelectionMode {
            toggleSelection(for: document)
            return
        }

        selectedDocument = nil
        withAnimation(selectionAnimation) {
            isSelectionMode = true
            selectedDocumentIDs = [document.id]
        }
        Haptics.selectionChanged()
    }

    private func toggleSelection(for document: ScannedDocument) {
        withAnimation(selectionAnimation) {
            if selectedDocumentIDs.contains(document.id) {
                selectedDocumentIDs.remove(document.id)
            } else {
                isSelectionMode = true
                selectedDocumentIDs.insert(document.id)
            }

            if selectedDocumentIDs.isEmpty {
                isSelectionMode = false
            }
        }
        Haptics.selectionChanged()
    }

    private func toggleSelectAll() {
        guard !displayedDocuments.isEmpty else { return }

        withAnimation(selectionAnimation) {
            isSelectionMode = true

            if allDisplayedSelected {
                selectedDocumentIDs.removeAll()
                isSelectionMode = false
            } else {
                selectedDocumentIDs = Set(displayedDocuments.map(\.id))
            }
        }
        Haptics.selectionChanged()
    }

    private func endSelectionMode() {
        withAnimation(selectionAnimation) {
            selectedDocumentIDs.removeAll()
            isSelectionMode = false
        }
    }

    private func deleteSelectedDocuments() {
        let documentsToDelete = selectedDocuments
        guard !documentsToDelete.isEmpty else { return }

        Task {
            isDeletingSelection = true
            await library.delete(documentsToDelete)
            isDeletingSelection = false

            if library.activeError == nil {
                endSelectionMode()
                Haptics.success()
            }
        }
    }

    private func pruneSelection(using availableIDs: Set<ScannedDocument.ID>) {
        let prunedSelection = selectedDocumentIDs.intersection(availableIDs)

        guard prunedSelection != selectedDocumentIDs else { return }

        selectedDocumentIDs = prunedSelection
        if selectedDocumentIDs.isEmpty {
            isSelectionMode = false
        }
    }
}

#Preview {
    LibraryView()
        .environmentObject(DocumentLibrary.preview)
}

private struct LibraryToolbarTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .appToolbarTitleSurface()
            .accessibilityAddTraits(.isHeader)
    }
}

private enum LibraryScrollCoordinateSpace {
    static let name = "library-scroll"
}

private struct LibraryScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct LibraryScrollPositionReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: LibraryScrollOffsetPreferenceKey.self,
                    value: proxy.frame(in: .named(LibraryScrollCoordinateSpace.name)).minY
                )
        }
        .frame(height: 0)
        .accessibilityHidden(true)
    }
}

private struct LibraryDocumentTile: View {
    let document: ScannedDocument
    let cardWidth: CGFloat?
    let isSelectionMode: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        DocumentCard(
            document: document,
            isSelectionMode: isSelectionMode,
            isSelected: isSelected
        )
        .frame(width: cardWidth, height: DocumentCardLayout.totalCardHeight)
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(document.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(isSelectionMode ? "Double tap to toggle selection." : "Double tap to open. Long press to start selecting.")
        .accessibilityAddTraits(.isButton)
    }
}

private struct LibrarySelectionBar: View {
    let selectionCount: Int
    let isDeleting: Bool
    let isMoving: Bool
    let moveAction: () -> Void
    let deleteAction: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectionCount == 1 ? "1 document selected" : "\(selectionCount) documents selected")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("Choose an action for the current selection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    moveButton
                    deleteButton
                }
            } else {
                HStack(spacing: 12) {
                    moveButton
                    deleteButton
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
    }

    private var moveButton: some View {
        Button(action: moveAction) {
            Label("Move", systemImage: "folder")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
        .disabled(selectionCount == 0 || isDeleting || isMoving)
    }

    private var deleteButton: some View {
        Button {
            guard !isDeleting else { return }
            deleteAction()
        } label: {
            Group {
                if isDeleting {
                    AppProminentProgressView(accessibilityLabel: "Deleting documents")
                        .controlSize(.regular)
                        .frame(height: 22)
                } else {
                    Label("Delete", systemImage: "trash")
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .appProminentButtonStyle(color: .red)
        .disabled(selectionCount == 0 || isMoving)
        .accessibilityLabel(isDeleting ? "Deleting documents" : "Delete")
    }
}

private struct FolderCard: View {
    let summary: FolderSummary

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summary.newestDocuments.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                    Image(systemName: "folder")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 142)
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(0..<4, id: \.self) { index in
                        if summary.newestDocuments.indices.contains(index) {
                            DocumentThumbnail(url: summary.newestDocuments[index].previewURL)
                                .frame(height: 68)
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                                .frame(height: 68)
                        }
                    }
                }
                .frame(height: 142)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.folder.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(summary.documentCount) document\(summary.documentCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.folder.name), \(summary.documentCount) documents")
        .accessibilityHint("Opens folder")
    }
}

private struct FolderNameSheet: View {
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

private struct FolderPickerSheet: View {
    let folders: [DocumentFolder]
    let commonFolderID: UUID?
    let hasCommonFolder: Bool
    let isMoving: Bool
    let onCreateFolder: @MainActor (String) async -> String?
    let onMove: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsNewFolder = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    destinationRow(name: "Unfiled", systemImage: "tray", id: nil)
                }

                Section("Folders") {
                    ForEach(folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
                        destinationRow(name: folder.name, systemImage: "folder", id: folder.id)
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

    private func destinationRow(name: String, systemImage: String, id: UUID?) -> some View {
        Button {
            onMove(id)
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

private struct AddDocumentsToFolderSheet: View {
    let documents: [ScannedDocument]
    let folderName: String
    let folderNamesByID: [UUID: String]
    let onAdd: @MainActor (Set<UUID>) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
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
                } else if filteredDocuments.isEmpty {
                    AppUnavailableStateView(
                        title: "No Results",
                        systemImage: "magnifyingglass",
                        description: "No document titles match your search."
                    )
                    .padding(.horizontal, 24)
                } else {
                    List(filteredDocuments) { document in
                        documentRow(document)
                    }
                    .listStyle(.insetGrouped)
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
        .alert("Couldn’t Add Documents", isPresented: addErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "Unknown error")
        }
    }

    private var filteredDocuments: [ScannedDocument] {
        let normalizedQuery = LibraryTextNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty else { return documents }
        return documents.filter {
            LibraryTextNormalizer.normalize($0.title).contains(normalizedQuery)
        }
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

private struct FolderDetailView: View {
    let folder: DocumentFolder

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var library: DocumentLibrary
    @State private var documents: [ScannedDocument] = []
    @State private var query = ""
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
                if isLoading {
                    ProgressView("Loading folder…")
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
            if isDeleting {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("Deleting folder…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        }
        .task(id: FolderDetailRequest(folderID: folder.id, query: query, reloadToken: reloadToken)) {
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            await loadDocuments()
        }
        .onChange(of: library.allDocuments) { _ in reloadToken = UUID() }
        .fullScreenCover(item: $selectedDocument) { document in
            DocumentDetailView(document: document).environmentObject(library)
        }
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
                message: "Choose a title before saving this scan to “\(displayName)”.",
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

    private func loadDocuments() async {
        isLoading = documents.isEmpty
        do {
            documents = try await library.queryDocuments(scope: .folder(folder.id), query: query)
            errorMessage = nil
            selectedDocumentIDs.formIntersection(Set(documents.map(\.id)))
            if selectedDocumentIDs.isEmpty { isSelectionMode = false }
        } catch {
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

private extension View {
    @ViewBuilder
    func librarySearchable(enabled: Bool, text: Binding<String>, prompt: String) -> some View {
        if enabled {
            searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }
}

private enum Haptics {
    static func selectionChanged() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
}
