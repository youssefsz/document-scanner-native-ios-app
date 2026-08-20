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

            VStack(spacing: 4) {
                Text(currentDocument.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text(currentDocument.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Page \(currentPageNumber) of \(renderedPages.count)")
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
        return min(max(currentPageID + 1, 1), renderedPages.count)
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
        isLoadingPreview = true
        previewErrorMessage = nil
        renderedPages = []
        currentPageID = nil
        showsControls = true
        zoomedPageID = nil

        let pdfDocument: PDFDocument
        if currentDocument.isSecure {
            guard let secureAccess else {
                previewErrorMessage = LibraryRepositoryError.secureAccessRequired.localizedDescription
                isLoadingPreview = false
                return
            }
            do {
                let data = try await library.secureAssetData(for: currentDocument, kind: .pdf, access: secureAccess)
                guard let decryptedDocument = PDFDocument(data: data), decryptedDocument.pageCount > 0 else {
                    throw DocumentExportError.sourceDocumentUnreadable
                }
                pdfDocument = decryptedDocument
            } catch {
                previewErrorMessage = error.localizedDescription
                isLoadingPreview = false
                return
            }
        } else {
            let url = currentDocument.pdfURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                previewErrorMessage = "The PDF file is missing from local storage."
                isLoadingPreview = false
                return
            }
            guard let storedDocument = PDFDocument(url: url), storedDocument.pageCount > 0 else {
                previewErrorMessage = "The PDF file exists, but the app could not read it."
                isLoadingPreview = false
                return
            }
            pdfDocument = storedDocument
        }

        let pages = (0..<pdfDocument.pageCount).compactMap { index -> DocumentPageSnapshot? in
            guard let page = pdfDocument.page(at: index) else { return nil }
            return DocumentPageSnapshot(id: index, image: DocumentPageRenderer.render(page: page))
        }

        guard !pages.isEmpty else {
            previewErrorMessage = "The PDF loaded, but no pages could be rendered."
            isLoadingPreview = false
            return
        }

        renderedPages = pages
        currentPageID = pages.first?.id
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

struct DocumentPageSnapshot: Identifiable {
    let id: Int
    let image: UIImage
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
