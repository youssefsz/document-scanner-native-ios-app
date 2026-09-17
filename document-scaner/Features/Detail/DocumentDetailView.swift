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
        _renderedPages = State(initialValue: preview.map { [0: DocumentPageSnapshot(id: 0, image: $0, isPreview: true)] } ?? [:])
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
    @State private var pageCount = 0
    @State private var pageSession: DocumentPageSession?
    @State private var pageLoadTasks: [Int: Task<Void, Never>] = [:]
    @State private var pageLoadTokens: [Int: UUID] = [:]
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
    @State private var exportPreviewTokens: [DocumentExportQuality: UUID] = [:]
    @State private var exportPasswords: PDFPasswordPair?
    @State private var isExportPasswordRevealed = false
    @State private var pendingShareQuality: DocumentExportQuality?
    @State private var pendingSharePresentation = false
    @State private var preparedExports: [DocumentExportQuality: PreparedDocumentExport] = [:]
    @State private var previewErrorMessage: String?
    @State private var renderedPages: [Int: DocumentPageSnapshot] = [:]
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
                .accessibilityHidden(!showsControls)

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
        .onChange(of: currentPageID) { pageID in
            guard let pageID else { return }
            loadVisiblePages(around: pageID)
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
            cancelPageLoads()
            pageSession = nil
            guard !isShowingShareSheet, !pendingSharePresentation else { return }
            cleanupPreparedExports()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            guard let pageSession else { return }
            let retained = Set([currentPageID ?? 0])
            for index in Array(renderedPages.keys) where !retained.contains(index) {
                renderedPages.removeValue(forKey: index)
            }
            Task { await pageSession.removeCachedPages(except: retained) }
        }
        .onChange(of: scenePhase) { phase in
            guard currentDocument.isSecure, phase != .active else { return }
            cancelPageLoads()
            pageSession = nil
            renderedPages = [:]
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
        } else if renderedPages.isEmpty && pageCount == 0 {
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
            pageCount: max(pageCount, renderedPages.isEmpty ? 0 : 1),
            snapshots: renderedPages,
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
                .frame(height: 150)
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
            .padding(.bottom, 16)
        }
        .animation(.easeInOut(duration: 0.2), value: showsControls)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .viewerChromeButtonStyle()
            .accessibilityLabel("Close document")
            .accessibilityIdentifier("document-viewer-close")

            VStack(spacing: 4) {
                Text(currentDocument.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(currentDocument.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Menu {
                Button(action: startRename) {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    if confirmBeforeDelete {
                        isShowingDeleteConfirmation = true
                    } else {
                        deleteDocument()
                    }
                } label: {
                    Label("Delete Document", systemImage: "trash")
                }
            } label: {
                if isRenaming {
                    ProgressView()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
            }
            .viewerChromeButtonStyle()
            .disabled(isDeleting || isPreparingShare || isRenaming)
            .accessibilityLabel("More document actions")
            .accessibilityIdentifier("document-viewer-more")
        }
    }

    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                pageIndicator
                    .fixedSize()
                Spacer(minLength: 8)
                shareButton
                    .fixedSize()
            }

            VStack(spacing: 12) {
                pageIndicator
                shareButton
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: 520)
    }

    private var pageIndicator: some View {
        Text(renderedPages.isEmpty
             ? (isLoadingPreview ? "Loading pages…" : "Preview unavailable")
             : "Page \(currentPageNumber) of \(max(pageCount, currentDocument.pageCount))")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .monospacedDigit()
            .accessibilityIdentifier("document-viewer-page-count")
    }

    private var shareButton: some View {
        Button(action: startShare) {
            if isPreparingShare {
                ProgressView()
                    .accessibilityLabel("Preparing PDF")
            } else {
                Label("Share PDF", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .viewerShareButtonStyle()
        .disabled(renderedPages.isEmpty || isDeleting || isRenaming || isPreparingShare)
        .accessibilityLabel(isPreparingShare ? "Preparing PDF" : "Share PDF")
        .accessibilityIdentifier("document-viewer-share")
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
        currentPageID = renderedPages[0] == nil ? nil : 0
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
                    renderedPages[0] = DocumentPageSnapshot(id: 0, image: preview, isPreview: true)
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
            let session = try await DocumentPageSession.open(from: source)
            guard !Task.isCancelled else { return }
            pageSession = session
            pageCount = session.pageCount
            let firstPage = try await session.page(at: 0)
            guard !Task.isCancelled else { return }
            renderedPages[0] = firstPage
            currentPageID = currentPageID ?? 0
            isLoadingPreview = false
            loadVisiblePages(around: currentPageID ?? 0)
        } catch {
            guard !Task.isCancelled else { return }
            showPreviewError(error.localizedDescription)
        }
    }

    private func showPreviewError(_ message: String) {
        pageCount = 0
        if renderedPages.values.allSatisfy(\.isPreview) {
            renderedPages = [:]
        }
        previewErrorMessage = message
        isLoadingPreview = false
    }

    private func loadVisiblePages(around center: Int) {
        guard let pageSession, pageCount > 0 else { return }
        let retained = Set(max(0, center - 2)...min(pageCount - 1, center + 2))
        for index in Array(pageLoadTasks.keys) where !retained.contains(index) {
            pageLoadTasks.removeValue(forKey: index)?.cancel()
            pageLoadTokens.removeValue(forKey: index)
        }
        for index in Array(renderedPages.keys) where !retained.contains(index) {
            renderedPages.removeValue(forKey: index)
        }
        for index in retained.sorted() where renderedPages[index] == nil && pageLoadTasks[index] == nil {
            let token = UUID()
            pageLoadTokens[index] = token
            pageLoadTasks[index] = Task { @MainActor in
                do {
                    let page = try await pageSession.page(at: index)
                    guard !Task.isCancelled, pageLoadTokens[index] == token else { return }
                    renderedPages[index] = page
                } catch is CancellationError {
                    // A page outside the visible window no longer needs rendering.
                } catch {
                    guard pageLoadTokens[index] == token else { return }
                    previewErrorMessage = error.localizedDescription
                }
                if pageLoadTokens[index] == token {
                    pageLoadTasks.removeValue(forKey: index)
                    pageLoadTokens.removeValue(forKey: index)
                }
            }
        }
    }

    private func cancelPageLoads() {
        pageLoadTasks.values.forEach { $0.cancel() }
        pageLoadTasks = [:]
        pageLoadTokens = [:]
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
        for otherQuality in Array(exportPreparationTasks.keys) where otherQuality != quality {
            exportPreparationTasks.removeValue(forKey: otherQuality)?.cancel()
            exportPreviewTokens.removeValue(forKey: otherQuality)
            exportPreviewLoadingQualities.remove(otherQuality)
        }
        guard preparedExports[quality] == nil else { return }
        guard !exportPreviewLoadingQualities.contains(quality) else { return }

        exportPreviewErrors[quality] = nil
        exportPreviewLoadingQualities.insert(quality)
        let token = UUID()
        exportPreviewTokens[quality] = token
        let documentToExport = currentDocument

        let task = Task {
            do {
                let preparedExport = try await Self.exportService.prepareExport(for: documentToExport, quality: quality)

                _ = await MainActor.run {
                    guard exportPreviewTokens[quality] == token else { return }
                    exportPreviewLoadingQualities.remove(quality)
                    exportPreparationTasks.removeValue(forKey: quality)
                    exportPreviewTokens.removeValue(forKey: quality)
                    exportPreviewErrors[quality] = nil
                    preparedExports[quality] = preparedExport

                }
            } catch is CancellationError {
                _ = await MainActor.run {
                    guard exportPreviewTokens[quality] == token else { return }
                    exportPreviewLoadingQualities.remove(quality)
                    exportPreparationTasks.removeValue(forKey: quality)
                    exportPreviewTokens.removeValue(forKey: quality)

                }
            } catch {
                _ = await MainActor.run {
                    guard exportPreviewTokens[quality] == token else { return }
                    exportPreviewLoadingQualities.remove(quality)
                    exportPreparationTasks.removeValue(forKey: quality)
                    exportPreviewTokens.removeValue(forKey: quality)
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
        let existingPreparation = exportPreparationTasks[quality]

        Task {
            do {
                if let existingPreparation {
                    await existingPreparation.value
                }
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
        exportPreviewTokens = [:]
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

private extension View {
    @ViewBuilder
    func viewerChromeButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(.white)
                .frame(minWidth: 44, minHeight: 44)
        } else {
            buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.white)
                .frame(minWidth: 44, minHeight: 44)
        }
    }

    @ViewBuilder
    func viewerShareButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.accentColor)
        } else {
            buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.accentColor)
        }
    }
}

nonisolated struct DocumentPageSnapshot: Identifiable, @unchecked Sendable {
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
