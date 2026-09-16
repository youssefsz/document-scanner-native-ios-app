//
//  DocumentDetailView.swift
//  document-scaner
//
//

import PDFKit
import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DocumentDetailView: View {
    let document: ScannedDocument
    var secureAccess: VaultAccess?

    init(document: ScannedDocument, secureAccess: VaultAccess? = nil) {
        self.document = document
        self.secureAccess = secureAccess
        let preview = document.isSecure ? nil : ThumbnailPipeline.shared.cachedPreviewImage(for: document.previewURL)
        _renderedPages = State(initialValue: preview.map { [DocumentPageSnapshot(id: 0, image: $0, isPreview: true)] } ?? [])
        _isLoadingPreview = State(initialValue: preview == nil)
        _secureTitleOverride = State(initialValue: document.isSecure ? document.title : nil)
    }

    @AppStorage(AppPreferenceKey.confirmBeforeDelete) private var confirmBeforeDelete = true
    @AppStorage(AppPreferenceKey.defaultExportQuality) private var defaultExportQuality = DocumentExportQuality.high.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: DocumentLibrary
    @EnvironmentObject private var proStore: ProStore

    @State private var currentPageID: Int?
    @State private var isDeleting = false
    @State private var isLoadingPreview = true
    @State private var isPreparingShare = false
    @State private var isRenaming = false
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingExportSheet = false
    @State private var isShowingRenameSheet = false
    @State private var isShowingShareSheet = false
    @State private var exportPreviewErrors: [DocumentExportQuality: String] = [:]
    @State private var exportPreviewLoadingQualities: Set<DocumentExportQuality> = []
    @State private var exportPreparationTasks: [DocumentExportQuality: Task<Void, Never>] = [:]
    @State private var exportPasswords: PDFPasswordPair?
    @State private var isExportPasswordRevealed = false
    @State private var pendingShareQuality: DocumentExportQuality?
    @State private var pendingSharePresentation = false
    @State private var preparedExports: [DocumentExportQuality: PreparedDocumentExport] = [:]
    @State private var previewErrorMessage: String?
    @State private var renderedPages: [DocumentPageSnapshot] = []
    @State private var requiresExportPassword = false
    @State private var selectedExportQuality = DocumentExportQuality.high
    @State private var shareItems: [Any] = []
    @State private var secureTitleOverride: String?
    @State private var stagedTitle = ""
    @State private var showsControls = true
    @State private var zoomedPageID: Int?
    private static let exportService = DocumentExportService()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content

            controlsOverlay
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)

            if isDeleting {
                deletingOverlay
            }

            if currentDocument.isSecure, scenePhase != .active {
                Color.black.ignoresSafeArea()
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .task(id: document.id) {
            await loadPages()
            await requestNativeReviewIfNeeded()
        }
        .confirmationDialog("Delete this document?", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Document", role: .destructive) {
                deleteDocument()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved PDF and preview from local storage.")
        }
        .sheet(isPresented: $isShowingExportSheet, onDismiss: presentPreparedShareIfNeeded) {
            DocumentExportSheet(
                selectedQuality: $selectedExportQuality,
                originalFileSize: currentDocument.isSecure ? nil : DocumentFileSizeFormatter.string(for: currentDocument.pdfURL),
                preparedExports: preparedExports,
                loadingQualities: exportPreviewLoadingQualities,
                isPreparingShare: isPreparingShare,
                exportErrorMessage: selectedExportPreviewError,
                requiresPassword: $requiresExportPassword,
                passwords: exportPasswords,
                isPasswordRevealed: $isExportPasswordRevealed,
                sourceIsSecure: currentDocument.isSecure,
                onCancel: {
                    isShowingExportSheet = false
                },
                onSelectionChange: ensurePreparedExport,
                onCopyPassword: copyExportPassword,
                onGeneratePassword: generateExportPasswords,
                onShare: {
                    prepareShare(using: selectedExportQuality)
                }
            )
            .proPaywallHost(store: proStore)
        }
        .sheet(isPresented: $isShowingShareSheet, onDismiss: {
            shareItems = []
            isPreparingShare = false
            cleanupPreparedExports()
        }) {
            ActivityShareSheet(activityItems: shareItems) {
                isShowingShareSheet = false
            }
        }
        .sheet(isPresented: $isShowingRenameSheet) {
            DocumentTitleEditorSheet(
                title: "Edit Document Name",
                message: "Update the title shown in your library and in this preview.",
                saveButtonTitle: "Save Changes",
                cancelButtonTitle: "Cancel",
                isSaving: isRenaming,
                documentTitle: $stagedTitle,
                onCancel: {
                    isShowingRenameSheet = false
                },
                onSave: saveRename
            )
        }
        .onDisappear {
            guard !isShowingShareSheet, !pendingSharePresentation else { return }
            cleanupPreparedExports()
        }
        .onChange(of: scenePhase) { phase in
            guard currentDocument.isSecure, phase != .active else { return }
            renderedPages = []
            shareItems = []
            dismiss()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoadingPreview {
            DocumentPreviewSkeleton()
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else if renderedPages.isEmpty {
            AppUnavailableStateView(
                title: "Preview Unavailable",
                systemImage: "doc.text.magnifyingglass",
                description: previewErrorMessage ?? "The saved PDF could not be loaded.",
                titleColor: .white,
                detailColor: .white.opacity(0.72)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .onTapGesture {
                toggleControls()
            }
        } else {
            pagedViewer
        }
    }

    private var pagedViewer: some View {
        DocumentPagePagerView(
            pages: renderedPages,
            currentPageID: $currentPageID,
            onSingleTap: toggleControls,
            onZoomStateChange: handleZoomStateChange
        )
        .accessibilityIdentifier("document-page-pager")
        .background(Color.black)
        .ignoresSafeArea()
    }

    private var controlsOverlay: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.78),
                        Color.black.opacity(0.2),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 190)

                Spacer()

                LinearGradient(
                    colors: [
                        .clear,
                        Color.black.opacity(0.22),
                        Color.black.opacity(0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 240)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .animation(.easeInOut(duration: 0.2), value: showsControls)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            ViewerControlButton(systemImage: "xmark") {
                dismiss()
            }
            .accessibilityLabel("Close document")
            .accessibilityIdentifier("document-viewer-close")

            VStack(spacing: 4) {
                Text(currentDocument.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(currentDocument.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            ViewerControlButton(
                systemImage: "pencil",
                isLoading: isRenaming,
                action: startRename
            )
            .disabled(isDeleting || isPreparingShare)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if !renderedPages.isEmpty {
                Text("Page \(currentPageNumber) of \(currentDocument.pageCount)")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
            }

            HStack {
                ViewerControlButton(
                    systemImage: "square.and.arrow.up",
                    isLoading: isPreparingShare,
                    action: startShare
                )
                .disabled(renderedPages.isEmpty || isDeleting || isRenaming)

                Spacer()

                ViewerControlButton(
                    systemImage: "trash",
                    isDestructive: true,
                    isLoading: isDeleting
                ) {
                    if confirmBeforeDelete {
                        isShowingDeleteConfirmation = true
                    } else {
                        deleteDocument()
                    }
                }
                .disabled(isPreparingShare || isRenaming)
            }
        }
    }

    private var deletingOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)

                Text("Deleting document...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .transition(.opacity)
    }

    private var currentPageNumber: Int {
        guard !renderedPages.isEmpty else { return 0 }
        guard let currentPageID else { return 1 }
        return min(max(currentPageID + 1, 1), currentDocument.pageCount)
    }

    private var currentDocument: ScannedDocument {
        if document.isSecure {
            var updated = document
            updated.title = secureTitleOverride ?? document.title
            return updated
        }
        return library.allDocuments.first(where: { $0.id == document.id }) ?? document
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showsControls.toggle()
        }
    }

    private func deleteDocument() {
        Task {
            guard !isDeleting else { return }
            isDeleting = true
            let didDelete: Bool
            if currentDocument.isSecure, let secureAccess {
                didDelete = await library.deleteSecure(currentDocument, access: secureAccess)
            } else {
                await library.delete(currentDocument)
                didDelete = library.activeError == nil
            }
            isDeleting = false

            if didDelete {
                dismiss()
            }
        }
    }

    private func startShare() {
        guard !isPreparingShare, !isDeleting, !isRenaming else { return }
        selectedExportQuality = preferredExportQuality
        pendingShareQuality = nil
        requiresExportPassword = currentDocument.isSecure
        isExportPasswordRevealed = false
        do {
            exportPasswords = try PDFPasswordGenerator().generate()
        } catch {
            library.activeError = LibraryError(message: error.localizedDescription)
            return
        }
        isShowingExportSheet = true
    }

    private func startRename() {
        guard !isDeleting, !isPreparingShare, !isRenaming else { return }

        stagedTitle = currentDocument.title
        isShowingRenameSheet = true
    }

    private func saveRename() {
        let title = stagedTitle
        let documentToRename = currentDocument

        guard !isRenaming else { return }

        isRenaming = true

        Task {
            let didRename: Bool
            if documentToRename.isSecure, let secureAccess {
                didRename = await library.renameSecure(documentToRename, title: title, access: secureAccess)
            } else {
                await library.rename(documentToRename, title: title)
                didRename = library.activeError == nil
            }
            isRenaming = false

            guard didRename else { return }

            if documentToRename.isSecure {
                secureTitleOverride = DocumentTitleFormatter.sanitized(title, fallbackDate: documentToRename.createdAt)
            }
            stagedTitle = self.currentDocument.title
            isShowingRenameSheet = false
        }
    }

    private func loadPages() async {
        isLoadingPreview = renderedPages.isEmpty
        previewErrorMessage = nil
        currentPageID = renderedPages.first?.id
        showsControls = true
        zoomedPageID = nil

        let source: DocumentPageSource
        if currentDocument.isSecure {
            guard let secureAccess else {
                showPreviewError(LibraryRepositoryError.secureAccessRequired.localizedDescription)
                return
            }
            do {
                if renderedPages.isEmpty,
                   let preview = await SecureThumbnailPipeline.shared.cachedPreviewImage(
                    documentID: document.id,
                    sessionID: secureAccess.sessionID
                   ) {
                    guard !Task.isCancelled else { return }
                    renderedPages = [DocumentPageSnapshot(id: 0, image: preview, isPreview: true)]
                    currentPageID = 0
                    isLoadingPreview = false
                }
                let data = try await library.secureAssetData(for: currentDocument, kind: .pdf, access: secureAccess)
                source = .data(data)
            } catch {
                showPreviewError(error.localizedDescription)
                return
            }
        } else {
            let url = currentDocument.pdfURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                showPreviewError("The PDF file is missing from local storage.")
                return
            }
            source = .url(url)
        }

        do {
            for try await page in DocumentPageLoader.pages(from: source) {
                guard !Task.isCancelled else { return }
                if renderedPages.first?.isPreview == true, page.id == 0 {
                    renderedPages[0] = page
                } else {
                    if renderedPages.first?.isPreview == true {
                        renderedPages = []
                    }
                    renderedPages.append(page)
                }
                if renderedPages.count == 1 {
                    currentPageID = page.id
                    isLoadingPreview = false
                }
            }
            guard !Task.isCancelled else { return }
            if renderedPages.allSatisfy(\.isPreview) {
                showPreviewError("The PDF loaded, but no pages could be rendered.")
            }
        } catch {
            guard !Task.isCancelled else { return }
            showPreviewError(error.localizedDescription)
        }
    }

    private func showPreviewError(_ message: String) {
        if renderedPages.allSatisfy(\.isPreview) {
            renderedPages = []
        }
        previewErrorMessage = message
        isLoadingPreview = false
    }

    private func handleZoomStateChange(for pageID: Int, isZoomed: Bool) {
        if isZoomed {
            zoomedPageID = pageID
        } else if zoomedPageID == pageID {
            zoomedPageID = nil
        }
    }

    private var preferredExportQuality: DocumentExportQuality {
        DocumentExportQuality(rawValue: defaultExportQuality) ?? .high
    }

    private var selectedPreparedExport: PreparedDocumentExport? {
        preparedExports[selectedExportQuality]
    }

    private var isLoadingSelectedExport: Bool {
        exportPreviewLoadingQualities.contains(selectedExportQuality)
    }

    private var selectedExportPreviewError: String? {
        exportPreviewErrors[selectedExportQuality]
    }

    private func presentPreparedShareIfNeeded() {
        if pendingSharePresentation {
            pendingSharePresentation = false
            isShowingShareSheet = true
        } else {
            cleanupPreparedExports()
        }
    }

    private func ensurePreparedExport(for quality: DocumentExportQuality) {
        // Secure documents are prepared only by the authorized export path below.
        // The ordinary size-preview path reads a URL and must never see vault bytes.
        guard !currentDocument.isSecure else { return }
        guard preparedExports[quality] == nil else { return }
        guard !exportPreviewLoadingQualities.contains(quality) else { return }

        exportPreviewErrors[quality] = nil
        exportPreviewLoadingQualities.insert(quality)
        let documentToExport = currentDocument

        let task = Task {
            do {
                let preparedExport = try await Self.exportService.prepareExport(for: documentToExport, quality: quality)

                _ = await MainActor.run {
                    exportPreviewLoadingQualities.remove(quality)
                    exportPreparationTasks.removeValue(forKey: quality)
                    exportPreviewErrors[quality] = nil
                    preparedExports[quality] = preparedExport

                }
            } catch is CancellationError {
                _ = await MainActor.run {
                    exportPreviewLoadingQualities.remove(quality)
                    exportPreparationTasks.removeValue(forKey: quality)

                }
            } catch {
                _ = await MainActor.run {
                    exportPreviewLoadingQualities.remove(quality)
                    exportPreparationTasks.removeValue(forKey: quality)
                    exportPreviewErrors[quality] = error.localizedDescription

                }
            }
        }

        exportPreparationTasks[quality] = task
    }

    private func prepareShare(using quality: DocumentExportQuality) {
        guard !isPreparingShare, let exportPasswords else { return }
        guard !requiresExportPassword || proStore.hasAccess(to: .passwordProtectedPDF) else {
            exportPreviewErrors[quality] = LibraryRepositoryError.proAccessRequired.localizedDescription
            return
        }

        isPreparingShare = true
        pendingShareQuality = quality
        let documentToExport = currentDocument
        let configuration = PDFExportConfiguration(
            quality: quality,
            requiresPassword: requiresExportPassword,
            passwords: exportPasswords,
            sourceProtection: documentToExport.protection
        )
        let proAccessGranted = proStore.hasAccess(to: .passwordProtectedPDF)

        Task {
            do {
                let authorizedSourceData: Data?
                if documentToExport.isSecure {
                    guard let secureAccess else { throw LibraryRepositoryError.secureAccessRequired }
                    authorizedSourceData = try await library.secureAssetData(
                        for: documentToExport,
                        kind: .pdf,
                        access: secureAccess
                    )
                } else {
                    authorizedSourceData = nil
                }
                let preparedExport = try await Self.exportService.prepareExport(
                    for: documentToExport,
                    configuration: configuration,
                    authorizedSourceData: authorizedSourceData,
                    proAccessGranted: proAccessGranted
                )
                await MainActor.run {
                    guard pendingShareQuality == quality else { return }
                    completeSharePreparation(with: preparedExport, quality: quality)
                }
            } catch {
                await MainActor.run {
                    guard pendingShareQuality == quality else { return }
                    pendingShareQuality = nil
                    isPreparingShare = false
                    exportPreviewErrors[quality] = error.localizedDescription
                }
            }
        }
    }

    private func completeSharePreparation(with preparedExport: PreparedDocumentExport, quality: DocumentExportQuality) {
        pendingShareQuality = nil
        defaultExportQuality = quality.rawValue
        shareItems = [preparedExport.url]
        pendingSharePresentation = true
        isShowingExportSheet = false
        isPreparingShare = false

        if !preparedExport.isPasswordProtected {
            exportPasswords = nil
        }
    }

    private func cleanupPreparedExports() {
        let documentToCleanup = currentDocument
        exportPreparationTasks.values.forEach { $0.cancel() }
        exportPreparationTasks = [:]
        preparedExports = [:]
        exportPreviewErrors = [:]
        exportPreviewLoadingQualities = []
        pendingShareQuality = nil
        isPreparingShare = false
        exportPasswords = nil
        isExportPasswordRevealed = false

        Task {
            await Self.exportService.removeTemporaryExports(for: documentToCleanup)
        }
    }

    @discardableResult
    private func generateExportPasswords() -> Bool {
        do {
            exportPasswords = try PDFPasswordGenerator().generate()
            isExportPasswordRevealed = false
            return true
        } catch {
            library.activeError = LibraryError(message: error.localizedDescription)
            return false
        }
    }

    private func copyExportPassword() {
        guard let exportPasswords else { return }
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: exportPasswords.pdfPassword]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(5 * 60)
            ]
        )
        UIAccessibility.post(notification: .announcement, argument: "Password copied for five minutes")
    }

    private func requestNativeReviewIfNeeded() async {
        guard !renderedPages.isEmpty else { return }
        guard AppReviewCoordinator.consumePendingReviewRequest(for: currentDocument) else { return }

        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }

        requestReview()
    }
}

private struct ViewerControlButton: View {
    let systemImage: String
    var isDestructive = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button {
            guard !isLoading else { return }
            action()
        } label: {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(isDestructive ? .red : .white)
                        .foregroundStyle(isDestructive ? .red : .white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 44, height: 44)
        }
        .appViewerControlButtonStyle(isDestructive: isDestructive)
    }
}

struct DocumentPageSnapshot: Identifiable, @unchecked Sendable {
    let id: Int
    let image: UIImage
    var isPreview = false
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async(execute: onComplete)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
