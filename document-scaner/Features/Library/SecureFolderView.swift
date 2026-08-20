//
//  SecureFolderView.swift
//  document-scaner
//
//

import SwiftUI
import UIKit

struct SecureFolderGate: View {
    let folder: DocumentFolder

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: DocumentLibrary
    @State private var access: VaultAccess?
    @State private var isAuthenticating = false
    @State private var pendingAccess: VaultAccess?
    @State private var isAwaitingActiveSceneAfterAuthentication = false
    @State private var isPresentingChildFlow = false

    init(folder: DocumentFolder, initialAccess: VaultAccess? = nil) {
        self.folder = folder
        _access = State(initialValue: initialAccess)
    }

    var body: some View {
        Group {
            if !folder.isSecure {
                FolderDetailView(folder: folder)
            } else if let access, access.isValid, scenePhase == .active {
                SecureFolderDetailView(
                    folder: folder,
                    access: access,
                    isPresentingChildFlow: $isPresentingChildFlow
                )
                    .privacySensitive()
            } else {
                lockedState
            }
        }
        .overlay {
            if folder.isSecure, scenePhase == .background {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .task {
            guard folder.isSecure, access == nil else { return }
            await unlock()
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
        .onDisappear {
            guard folder.isSecure, !isPresentingChildFlow else { return }
            library.lockSecureFolder(id: folder.id)
            access = nil
        }
    }

    private var lockedState: some View {
        VStack(spacing: 14) {
            if isAuthenticating {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel("Authenticating")
            }

            Text(isAuthenticating ? "Unlocking..." : "Folder locked")
                .font(.headline)

            Text("Authenticate to view this folder's documents.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !isAuthenticating {
                Button("Unlock") {
                    Task { await unlock() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityLabel("Unlock \(folder.name)")
            }
        }
        .padding(32)
        .appGroupedScreenBackground()
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeInOut(duration: 0.2), value: isAuthenticating)
    }

    private func shouldLock(for phase: ScenePhase) -> Bool {
        guard folder.isSecure else { return false }
        if phase == .background { return true }
        return phase == .inactive && !isAuthenticating && !library.isAuthenticatingSecureContent
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active, isAwaitingActiveSceneAfterAuthentication {
            access = pendingAccess
            pendingAccess = nil
            isAwaitingActiveSceneAfterAuthentication = false
            isAuthenticating = false
            return
        }

        guard shouldLock(for: phase) else { return }
        pendingAccess = nil
        isAwaitingActiveSceneAfterAuthentication = false
        isAuthenticating = false
        access = nil
    }

    private func unlock() async {
        guard !isAuthenticating, scenePhase == .active else { return }
        isAuthenticating = true
        await Task.yield()

        let unlockedAccess = await library.unlockSecureFolder(folder)
        switch scenePhase {
        case .active:
            access = unlockedAccess
            isAuthenticating = false
        case .inactive:
            pendingAccess = unlockedAccess
            isAwaitingActiveSceneAfterAuthentication = true
        case .background:
            library.lockSecureFolder(id: folder.id)
            isAuthenticating = false
        @unknown default:
            library.lockSecureFolder(id: folder.id)
            isAuthenticating = false
        }
    }
}

private struct SecureFolderDetailView: View {
    let folder: DocumentFolder
    let access: VaultAccess
    @Binding var isPresentingChildFlow: Bool

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
    @State private var selectedDocumentIDs: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showsMove = false
    @State private var showsDelete = false
    @State private var isMoving = false
    @State private var isDeleting = false
    @State private var showsAddDocuments = false
    @State private var isScannerPresented = false
    @State private var isNamingPendingScan = false
    @State private var isSavingPendingScan = false
    @State private var pendingScanPages: [UIImage] = []
    @State private var pendingScanTitle = ""

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Opening secure folder...")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 100)
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
                        Button("Scan into Folder", systemImage: "document.viewfinder") {
                            requestProFeature(.secureFolder) { openScanner() }
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
        .task(id: access.sessionID) { await loadDocuments() }
        .fullScreenCover(item: $selectedDocument, onDismiss: {
            isPresentingChildFlow = false
            Task { await loadDocuments() }
        }) { document in
            DocumentDetailView(document: document, secureAccess: access)
                .environmentObject(library)
        }
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
                    pendingScanPages = pages
                    pendingScanTitle = DocumentTitleFormatter.default(for: .now)
                    Task { @MainActor in
                        await Task.yield()
                        isNamingPendingScan = true
                    }
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
                message: "Choose a title before saving this scan to \(folder.name).",
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
