//
//  SecureFolderView.swift
//  document-scaner
//
//

import SwiftUI
import UIKit

enum SecureFolderPresentation {
    case locked
    case opening
    case documents(VaultAccess)

    init(access: VaultAccess?, isAuthenticating: Bool, scenePhase: ScenePhase) {
        if let access, access.isValid {
            self = scenePhase == .active ? .documents(access) : .opening
        } else {
            self = isAuthenticating ? .opening : .locked
        }
    }
}

struct SecureFolderGate: View {
    let folder: DocumentFolder

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: DocumentLibrary
    @State private var access: VaultAccess?
    @State private var unlockAttempt: UUID?
    @State private var unlockError: String?
    @State private var needsRecovery: Bool
    @State private var showsRecovery = false
    @State private var isPresentingChildFlow = false

    init(folder: DocumentFolder, initialAccess: VaultAccess? = nil, needsRecovery: Bool = false) {
        self.folder = folder
        _access = State(initialValue: initialAccess)
        _needsRecovery = State(initialValue: needsRecovery)
    }

    var body: some View {
        Group {
            if !folder.isSecure {
                FolderDetailView(folder: folder)
            } else {
                switch SecureFolderPresentation(
                    access: access, isAuthenticating: unlockAttempt != nil, scenePhase: scenePhase
                ) {
                case .documents(let access):
                    SecureFolderDetailView(
                        folder: folder,
                        access: access,
                        isPresentingChildFlow: $isPresentingChildFlow,
                        showsRecovery: $showsRecovery
                    )
                    .privacySensitive()
                case .opening:
                    SecureFolderOpeningIndicator()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .appGroupedScreenBackground()
                        .navigationTitle(folder.name)
                        .navigationBarTitleDisplayMode(.inline)
                case .locked:
                    lockedState
                }
            }
        }
        .overlay {
            if folder.isSecure, scenePhase == .background {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .task {
            guard folder.isSecure, access == nil, !needsRecovery else { return }
            await unlock()
        }
        .sheet(isPresented: $showsRecovery, onDismiss: { isPresentingChildFlow = false }) {
            NavigationStack { VaultRecoveryView(mode: needsRecovery ? .restore : .secureFolder) }
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
        .onDisappear {
            guard folder.isSecure, !isPresentingChildFlow else { return }
            clearUnlock()
            library.lockSecureFolder(id: folder.id)
        }
    }

    private var lockedState: some View {
        GeometryReader { geometry in
            ScrollView {
                lockedContent
                    .frame(maxWidth: 440)
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .appGroupedScreenBackground()
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var lockedContent: some View {
        VStack(spacing: 14) {
            if needsRecovery {
                VaultFolderIllustration(size: 94)
            }

            Text(needsRecovery ? "Vault recovery needed" : "Folder locked")
                .font(.headline)

            Text(needsRecovery
                 ? VaultAuthenticationError.recoveryRequired.localizedDescription
                 : unlockError ?? "Authenticate to view this folder’s documents.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if needsRecovery {
                Button("Restore Vault Backup") { showsRecovery = true }
                    .buttonStyle(.borderedProminent)
                Button("Try Unlock Again") { Task { await unlock() } }
                    .buttonStyle(.bordered)
            } else {
                Button("Unlock") { Task { await unlock() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Unlock \(folder.name)")
            }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        guard folder.isSecure else { return }
        if phase == .background ||
            (phase == .inactive && unlockAttempt == nil && !library.isAuthenticatingSecureContent) {
            clearUnlock()
        }
    }

    private func clearUnlock() {
        unlockAttempt = nil
        access = nil
    }

    private func unlock() async {
        guard unlockAttempt == nil, scenePhase == .active else { return }
        let attempt = UUID()
        unlockAttempt = attempt
        defer {
            if unlockAttempt == attempt { unlockAttempt = nil }
        }

        do {
            let unlockedAccess = try await library.unlockSecureFolder(folder)
            guard unlockAttempt == attempt, !Task.isCancelled else {
                unlockedAccess.invalidate()
                return
            }
            // SwiftUI renders the authorized folder only when the scene is active.
            // Authentication can finish before or after that scene transition.
            access = unlockedAccess
            needsRecovery = false
            unlockError = nil
        } catch {
            guard unlockAttempt == attempt else { return }
            if let issue = error as? VaultAuthenticationError {
                if issue == .cancelled { return }
                needsRecovery = issue == .recoveryRequired
            }
            if !(error is CancellationError) { unlockError = error.localizedDescription }
        }
    }
}

private struct SecureFolderOpeningIndicator: View {
    var body: some View {
        ProgressView("Opening secure folder…")
            .frame(maxWidth: .infinity)
            .padding(.top, 100)
    }
}

private struct SecureFolderDetailView: View {
    let folder: DocumentFolder
    let access: VaultAccess
    @Binding var isPresentingChildFlow: Bool
    @Binding var showsRecovery: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.requestProFeature) private var requestProFeature
    @EnvironmentObject private var library: DocumentLibrary
    @EnvironmentObject private var proStore: ProStore
    @State private var documents: [ScannedDocument] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDocument: ScannedDocument?
    @Namespace private var documentHeroNamespace
    @State private var selectedDocumentIDs: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showsMove = false
    @State private var showsDelete = false
    @State private var isMoving = false
    @State private var isDeleting = false
    @State private var showsAddDocuments = false
    @State private var isScannerPresented = false
    @State private var isPhotoImporterPresented = false
    @State private var photoImportProgress: PhotoImportProgress?
    @State private var isNamingPendingScan = false
    @State private var isSavingPendingScan = false
    @State private var pendingScanPages: [UIImage] = []
    @State private var pendingScanTitle = ""

    var body: some View {
        ScrollView {
            if isLoading {
                SecureFolderOpeningIndicator()
                    .transition(contentTransition)
            } else if let errorMessage {
                AppUnavailableStateView(
                    title: "Secure Folder Unavailable",
                    systemImage: "lock.trianglebadge.exclamationmark",
                    description: errorMessage
                )
                .padding(.horizontal, 24)
                .padding(.top, 80)
                .transition(contentTransition)
            } else if filteredDocuments.isEmpty {
                AppUnavailableStateView(
                    title: query.isEmpty ? "Folder Is Empty" : "No Results",
                    systemImage: query.isEmpty ? "lock.doc" : "magnifyingglass",
                    description: query.isEmpty ? "This secure folder has no documents." : "No document titles match your search."
                )
                .padding(.horizontal, 24)
                .padding(.top, 80)
                .transition(contentTransition)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredDocuments) { document in
                        SecureDocumentCard(document: document, access: access)
                            .onTapGesture { handleTap(document) }
                            .onLongPressGesture(minimumDuration: 0.35) { beginSelection(document) }
                            .accessibilityAddTraits(.isButton)
                            .documentHeroSource(
                                id: document.id,
                                in: documentHeroNamespace,
                                enabled: !accessibilityReduceMotion
                            )
                    }
                }
                .padding(16)
                .padding(.bottom, 40)
                .transition(contentTransition)
            }
        }
        .appGroupedScreenBackground()
        .animation(contentAnimation, value: isLoading)
        .animation(contentAnimation, value: errorMessage)
        .animation(contentAnimation, value: documents.map(\.id))
        .navigationTitle(isSelectionMode ? "\(selectedDocumentIDs.count) Selected" : folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search document titles")
        .toolbar {
            if isSelectionMode {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: endSelection)
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
                        Button("Vault Transfer & Backup", systemImage: "lock.shield") {
                            isPresentingChildFlow = true
                            showsRecovery = true
                        }
                        Button("Scan into Folder", systemImage: "document.viewfinder") {
                            requestProFeature(.secureFolder) { openScanner() }
                        }
                        Button("Import Photos", systemImage: "photo.on.rectangle") {
                            requestProFeature(.secureFolder) { isPhotoImporterPresented = true }
                        }
                        Button("Add Existing Documents", systemImage: "doc.badge.plus") {
                            requestProFeature(.secureFolder) { showsAddDocuments = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Secure Folder Actions")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if isSelectionMode {
                LibrarySelectionBar(
                    selectionCount: selectedDocumentIDs.count,
                    isDeleting: isDeleting,
                    isMoving: isMoving,
                    moveAction: { showsMove = true },
                    deleteAction: { showsDelete = true }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .overlay {
            if let photoImportProgress {
                PhotoImportProgressOverlay(progress: photoImportProgress)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .pending = access.transferStatus {
                Button {
                    isPresentingChildFlow = true
                    showsRecovery = true
                } label: {
                    Label("Vault transfer setup is incomplete", systemImage: "exclamationmark.shield")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                }
                .background(.regularMaterial)
            }
        }
        .task(id: access.sessionID) { await loadDocuments() }
        .fullScreenCover(item: $selectedDocument, onDismiss: {
            isPresentingChildFlow = false
            Task { await loadDocuments() }
        }) { document in
            DocumentDetailView(document: document, secureAccess: access)
                .environmentObject(library)
                .documentHeroDestination(
                    id: document.id,
                    in: documentHeroNamespace,
                    reduceMotion: accessibilityReduceMotion
                )
        }
        .documentPhotoImporter(
            isPresented: $isPhotoImporterPresented,
            progress: $photoImportProgress,
            onComplete: preparePendingScan,
            onError: { error in
                library.activeError = LibraryError(message: error.localizedDescription)
            }
        )
        .sheet(isPresented: $showsMove) {
            FolderPickerSheet(
                folders: library.allFolders.map(\.folder),
                commonFolderID: folder.id,
                hasCommonFolder: true,
                isMoving: isMoving,
                onCreateFolder: { name in
                    await library.createFolder(name: name) ? nil : library.consumeActiveErrorMessage()
                },
                onMove: moveSelection
            )
            .proPaywallHost(store: proStore)
        }
        .sheet(isPresented: $showsAddDocuments) {
            AddDocumentsToFolderSheet(
                documents: library.allDocuments,
                folderName: folder.name,
                folderNamesByID: Dictionary(
                    uniqueKeysWithValues: library.allFolders.map { ($0.id, $0.folder.name) }
                ),
                onAdd: addExistingDocuments
            )
        }
        .sheet(isPresented: $isScannerPresented) {
            DocumentScannerSheet(
                onComplete: { pages in
                    isScannerPresented = false
                    preparePendingScan(pages)
                },
                onCancel: { isScannerPresented = false },
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
                message: "Choose a title before saving this document to \(folder.name).",
                saveButtonTitle: "Save to Secure Folder",
                cancelButtonTitle: "Discard",
                isSaving: isSavingPendingScan,
                allowsInteractiveDismiss: false,
                documentTitle: $pendingScanTitle,
                onCancel: {
                    pendingScanPages = []
                    pendingScanTitle = ""
                    isNamingPendingScan = false
                },
                onSave: saveSecureScan
            )
        }
        .confirmationDialog(
            selectedDocumentIDs.count == 1 ? "Delete 1 secure document?" : "Delete \(selectedDocumentIDs.count) secure documents?",
            isPresented: $showsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Documents", role: .destructive, action: deleteSelection)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the encrypted PDFs, previews, and titles from this device.")
        }
        .onDisappear { query = "" }
    }

    private var filteredDocuments: [ScannedDocument] {
        let normalized = LibraryTextNormalizer.normalize(query)
        guard !normalized.isEmpty else { return documents }
        return documents.filter { LibraryTextNormalizer.normalize($0.title).contains(normalized) }
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count)
    }

    private var contentAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private var contentTransition: AnyTransition {
        accessibilityReduceMotion ? .identity : .opacity
    }

    private func loadDocuments() async {
        do {
            documents = try await library.secureFolderDocuments(folderID: folder.id, access: access)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func handleTap(_ document: ScannedDocument) {
        if isSelectionMode {
            toggleSelection(document)
        } else {
            isPresentingChildFlow = true
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

    private func moveSelection(to destinationID: UUID?) {
        let ids = selectedDocumentIDs
        Task {
            isMoving = true
            let success = await library.moveSecureDocuments(
                ids: ids,
                from: folder.id,
                to: destinationID,
                access: access
            )
            isMoving = false
            if success {
                showsMove = false
                endSelection()
                await loadDocuments()
            }
        }
    }

    private func deleteSelection() {
        let selected = documents.filter { selectedDocumentIDs.contains($0.id) }
        Task {
            isDeleting = true
            let success = await library.deleteSecure(selected, access: access)
            isDeleting = false
            if success {
                endSelection()
                await loadDocuments()
            }
        }
    }

    private func addExistingDocuments(_ ids: Set<UUID>) async -> String? {
        let success = await library.addNormalDocumentsToSecure(
            ids: ids,
            destination: folder,
            access: access
        )
        if success {
            await loadDocuments()
            return nil
        }
        return library.consumeActiveErrorMessage()
    }

    private func openScanner() {
        guard DocumentScannerSheet.isSupported else {
            library.activeError = LibraryError(message: "Document scanning requires a physical iPhone or iPad with camera access.")
            return
        }
        isScannerPresented = true
    }

    private func preparePendingScan(_ pages: [UIImage]) {
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

    private func saveSecureScan() {
        let pages = pendingScanPages
        let title = pendingScanTitle
        guard !pages.isEmpty, !isSavingPendingScan else { return }
        isSavingPendingScan = true
        Task {
            let success = await library.importSecureScan(
                pages: pages,
                title: title,
                destination: folder,
                access: access
            )
            isSavingPendingScan = false
            if success {
                pendingScanPages = []
                pendingScanTitle = ""
                isNamingPendingScan = false
                await loadDocuments()
                Haptics.success()
            }
        }
    }
}

private struct SecureDocumentCard: View {
    let document: ScannedDocument
    let access: VaultAccess

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var library: DocumentLibrary
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: DocumentCardLayout.thumbnailCornerRadius, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .transition(accessibilityReduceMotion ? .identity : .opacity)
                    } else {
                        ProgressView()
                    }
                }
                .task(id: SecureThumbnailRequest(documentID: document.id, size: proxy.size)) {
                    await loadImage(size: proxy.size)
                }
            }
            .frame(height: DocumentCardLayout.thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: DocumentCardLayout.thumbnailCornerRadius, style: .continuous))

            Text(document.title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
            Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minHeight: DocumentCardLayout.totalCardHeight, alignment: .top)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(document.title), secure document")
    }

    private func loadImage(size: CGSize) async {
        let scale = UIScreen.main.scale
        if let cached = await SecureThumbnailPipeline.shared.cachedImage(
            documentID: document.id,
            sessionID: access.sessionID,
            pointSize: size,
            scale: scale
        ) {
            setImage(cached)
            return
        }
        guard let data = try? await library.secureAssetData(for: document, kind: .preview, access: access) else { return }
        let loadedImage = await SecureThumbnailPipeline.shared.image(
            from: data,
            documentID: document.id,
            sessionID: access.sessionID,
            pointSize: size,
            scale: scale
        )
        guard !Task.isCancelled else { return }
        setImage(loadedImage)
    }

    private func setImage(_ newImage: UIImage?) {
        if accessibilityReduceMotion {
            image = newImage
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                image = newImage
            }
        }
    }
}

private struct SecureThumbnailRequest: Equatable {
    let documentID: UUID
    let width: Int
    let height: Int

    init(documentID: UUID, size: CGSize) {
        self.documentID = documentID
        width = Int(size.width.rounded())
        height = Int(size.height.rounded())
    }
}
