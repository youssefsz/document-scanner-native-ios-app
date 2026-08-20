//
//  LibraryView.swift
//  document-scaner
//
//

import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var library: DocumentLibrary
    @EnvironmentObject private var proStore: ProStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.requestProFeature) private var requestProFeature

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
    @State private var folderSecurityChange: FolderSecurityChangeRequest?
    @State private var folderNavigationPath: [DocumentFolder] = []
    @State private var authenticatingFolderID: UUID?
    @State private var pendingSecureFolderNavigation: DocumentFolder?
    @State private var isDeletingFolder = false
    @State private var pendingScanPages: [UIImage] = []
    @State private var pendingScanTitle = ""
    @State private var selectedDocument: ScannedDocument?
    @State private var selectedDocumentIDs: Set<ScannedDocument.ID> = []

    private let gridSpacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        NavigationStack(path: $folderNavigationPath) {
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
                .appGroupedScreenBackground()
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
                    SecureFolderGate(
                        folder: folder,
                        initialAccess: folder.isSecure
                            ? library.activeSecureFolderAccess(for: folder.id)
                            : nil
                    )
                        .environmentObject(library)
                }
            }
        }
        .animation(selectionAnimation, value: isSelectionMode)
        .animation(selectionAnimation, value: selectedDocumentIDs)
        .animation(bottomAccessoryAnimation, value: library.selectedSection)
        .animation(searchResultsAnimation, value: library.documents.map(\.id))
        .animation(searchResultsAnimation, value: library.folders.map(\.id))
        .animation(searchResultsAnimation, value: library.isDocumentSearchPending)
        .animation(searchResultsAnimation, value: library.isFolderSearchPending)
        .task {
            library.updateSortOrder(rawValue: documentSortOrder)
            await library.loadIfNeeded()
        }
        .onChange(of: documentSortOrder) { value in
            library.updateSortOrder(rawValue: value)
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
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
            NewFolderSheet(
                validation: { library.folderNameValidationMessage($0) },
                onSave: { name, security in
                    let success = await library.createFolder(name: name, security: security)
                    return (success, success ? nil : library.consumeActiveErrorMessage())
                }
            )
            .proPaywallHost(store: proStore)
        }
        .sheet(item: $folderSecurityChange) { request in
            FolderSecurityChangeSheet(
                request: request,
                progress: library.securityConversionProgress[request.folder.id],
                onCancel: {
                    library.cancelSecurityConversion(folderID: request.folder.id)
                    folderSecurityChange = nil
                },
                onConfirm: {
                    await library.changeFolderSecurity(request.folder, to: request.target)
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
            .proPaywallHost(store: proStore)
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
            if library.isDocumentSearchPending {
                searchLoadingState(title: "Searching Documents…")
                    .transition(.opacity)
            } else {
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
                .transition(.opacity)
            }
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
            .transition(.opacity)
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
            if library.isFolderSearchPending {
                searchLoadingState(title: "Searching Folders…")
                    .transition(.opacity)
            } else {
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
                .transition(.opacity)
            }
        } else {
            LazyVGrid(columns: columns, alignment: .center, spacing: gridSpacing) {
                ForEach(library.folders) { summary in
                    Button {
                        openFolder(summary.folder)
                    } label: {
                        FolderCard(
                            summary: summary,
                            isAuthenticating: authenticatingFolderID == summary.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(authenticatingFolderID != nil)
                    .contextMenu {
                        Button {
                            folderBeingRenamed = summary.folder
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            let request = FolderSecurityChangeRequest(
                                folder: summary.folder,
                                documentCount: summary.documentCount,
                                target: summary.folder.isSecure ? .standard : .secure
                            )
                            if summary.folder.isSecure {
                                folderSecurityChange = request
                            } else {
                                requestProFeature(.secureFolder) {
                                    folderSecurityChange = request
                                }
                            }
                        } label: {
                            Label(
                                summary.folder.isSecure ? "Remove Security" : "Make Secure",
                                systemImage: summary.folder.isSecure ? "lock.open" : "lock.fill"
                            )
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
            .transition(.opacity)
        }
    }

    private func openFolder(_ folder: DocumentFolder) {
        guard authenticatingFolderID == nil else { return }
        guard folder.isSecure else {
            folderNavigationPath.append(folder)
            return
        }

        authenticatingFolderID = folder.id
        Task { @MainActor in
            let access = await library.unlockSecureFolder(folder)
            guard authenticatingFolderID == folder.id else {
                if access?.isValid == true {
                    library.lockSecureFolder(id: folder.id)
                }
                return
            }
            guard access?.isValid == true else {
                authenticatingFolderID = nil
                return
            }

            switch scenePhase {
            case .active:
                finishOpeningSecureFolder(folder)
            case .inactive:
                pendingSecureFolderNavigation = folder
            case .background:
                library.lockSecureFolder(id: folder.id)
                authenticatingFolderID = nil
            @unknown default:
                library.lockSecureFolder(id: folder.id)
                authenticatingFolderID = nil
            }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        if phase == .background {
            pendingSecureFolderNavigation = nil
            authenticatingFolderID = nil
            return
        }

        guard phase == .active, let folder = pendingSecureFolderNavigation else { return }
        guard library.activeSecureFolderAccess(for: folder.id)?.isValid == true else {
            pendingSecureFolderNavigation = nil
            authenticatingFolderID = nil
            return
        }
        finishOpeningSecureFolder(folder)
    }

    private func finishOpeningSecureFolder(_ folder: DocumentFolder) {
        pendingSecureFolderNavigation = nil
        authenticatingFolderID = nil
        folderNavigationPath.append(folder)
    }

    private func searchLoadingState(title: String) -> some View {
        ProgressView(title)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
            .padding(.top, 100)
            .accessibilityLabel(title)
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
                SearchAwareScanAccessory {
                    floatingScanButton
                }
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

    private var searchResultsAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)
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
        .environmentObject(ProStore(productIdentifier: nil, startLifecycle: false))
}
