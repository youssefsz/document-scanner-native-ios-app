//
//  DocumentDetailView.swift
//  document-scaner
//
//

import AVFoundation
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

        isPreparingShare = true
        pendingShareQuality = quality
        let documentToExport = currentDocument
        let configuration = PDFExportConfiguration(
            quality: quality,
            requiresPassword: requiresExportPassword,
            passwords: exportPasswords,
            sourceProtection: documentToExport.protection
        )

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
                    authorizedSourceData: authorizedSourceData
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

private struct DocumentPageSnapshot: Identifiable {
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

private struct DocumentExportSheet: View {
    @Binding var selectedQuality: DocumentExportQuality
    let originalFileSize: String?
    let preparedExports: [DocumentExportQuality: PreparedDocumentExport]
    let loadingQualities: Set<DocumentExportQuality>
    let isPreparingShare: Bool
    let exportErrorMessage: String?
    @Binding var requiresPassword: Bool
    let passwords: PDFPasswordPair?
    @Binding var isPasswordRevealed: Bool
    let sourceIsSecure: Bool
    let onCancel: () -> Void
    let onSelectionChange: (DocumentExportQuality) -> Void
    let onCopyPassword: () -> Void
    let onGeneratePassword: () -> Bool
    let onShare: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DocumentExportQuality.allCases) { quality in
                        Button {
                            selectedQuality = quality
                        } label: {
                            ExportQualityRow(
                                quality: quality,
                                isSelected: selectedQuality == quality,
                                sizeText: preparedExports[quality]?.formattedFileSize,
                                isLoading: loadingQualities.contains(quality)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparingShare)
                    }
                } header: {
                    Text("Export Quality")
                } footer: {
                    Text("Smaller files are easier to email and upload. The original document saved in your library stays unchanged.")
                }

                Section {
                    PDFExportSecurityCard(
                        requiresPassword: $requiresPassword,
                        passwords: passwords,
                        isPasswordRevealed: $isPasswordRevealed,
                        isPreparingShare: isPreparingShare,
                        onCopyPassword: onCopyPassword,
                        onGeneratePassword: onGeneratePassword
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Security")
                } footer: {
                    if sourceIsSecure && !requiresPassword {
                        Text("This shared copy will not require a password.")
                    } else {
                        Text("Password protection applies only to the shared copy. The library original remains unchanged.")
                    }
                }

                Section {
                    LabeledContent("Saved File Size", value: originalFileSize ?? "Unavailable")
                } header: {
                    Text("Current PDF")
                } footer: {
                    if let exportErrorMessage {
                        Text(exportErrorMessage)
                    }
                }
            }
            .navigationTitle("Share PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isPreparingShare)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onShare) {
                        if isPreparingShare {
                            AppToolbarProgressView(accessibilityLabel: "Preparing PDF")
                        } else {
                            Text("Share")
                        }
                    }
                    .accessibilityLabel(isPreparingShare ? "Preparing PDF" : "Share")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            onSelectionChange(selectedQuality)
        }
        .onChange(of: selectedQuality) { newValue in
            onSelectionChange(newValue)
        }
    }
}

private struct PDFExportSecurityCard: View {
    @Binding var requiresPassword: Bool
    let passwords: PDFPasswordPair?
    @Binding var isPasswordRevealed: Bool
    let isPreparingShare: Bool
    let onCopyPassword: () -> Void
    let onGeneratePassword: () -> Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var feedback: PasswordActionFeedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: requiresPassword ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(requiresPassword ? Color.accentColor : Color.secondary)
                    .frame(width: 42, height: 42)
                    .background(
                        (requiresPassword ? Color.accentColor : Color.secondary)
                            .opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Require password")
                        .font(.body.weight(.semibold))

                    Text(requiresPassword ? "Protect this shared copy." : "Anyone can open this shared copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle("Require password", isOn: $requiresPassword)
                    .labelsHidden()
                    .disabled(isPreparingShare)
            }

            if requiresPassword, let passwords {
                Divider()

                passwordPanel(passwords)

                actionButtons

                if let feedback {
                    Label(feedback.message, systemImage: feedback.systemImage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(feedback.color)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(18)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
        .animation(.easeInOut(duration: 0.2), value: requiresPassword)
        .animation(.easeInOut(duration: 0.2), value: feedback)
        .onChange(of: requiresPassword) { _ in
            feedback = nil
            isPasswordRevealed = false
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func passwordPanel(_ passwords: PDFPasswordPair) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PDF password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Button {
                    isPasswordRevealed.toggle()
                    feedback = nil
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Label(
                        isPasswordRevealed ? "Hide" : "Show",
                        systemImage: isPasswordRevealed ? "eye.slash" : "eye"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(isPreparingShare)
                .accessibilityLabel(isPasswordRevealed ? "Hide PDF password" : "Show PDF password")
            }

            Text(isPasswordRevealed ? passwords.displayedUserPassword : "••••-••••-••••-••••")
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .privacySensitive()
                .accessibilityLabel(isPasswordRevealed ? passwords.displayedUserPassword : "Password hidden")

            Text("Use this password exactly as shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            Color(.tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                copyButton
                generateButton
            }
        } else {
            HStack(spacing: 10) {
                copyButton
                generateButton
            }
        }
    }

    private var copyButton: some View {
        Button(action: copyPassword) {
            Label(
                feedback == .copied ? "Copied" : "Copy password",
                systemImage: feedback == .copied ? "checkmark" : "doc.on.doc"
            )
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .appProminentButtonStyle()
        .disabled(isPreparingShare)
        .accessibilityLabel(feedback == .copied ? "Password copied" : "Copy PDF password for five minutes")
    }

    private var generateButton: some View {
        Button(action: generatePassword) {
            Label(
                feedback == .generated ? "Generated" : "New password",
                systemImage: feedback == .generated ? "checkmark" : "arrow.clockwise"
            )
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .disabled(isPreparingShare)
        .accessibilityLabel(feedback == .generated ? "New password generated" : "Generate a new PDF password")
    }

    private func copyPassword() {
        onCopyPassword()
        showFeedback(.copied)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func generatePassword() {
        guard onGeneratePassword() else { return }
        showFeedback(.generated)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: "A new PDF password is ready")
    }

    private func showFeedback(_ newFeedback: PasswordActionFeedback) {
        feedback = newFeedback
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard feedback == newFeedback else { return }
            withAnimation { feedback = nil }
        }
    }
}

private enum PasswordActionFeedback: Equatable {
    case copied
    case generated

    var message: String {
        switch self {
        case .copied:
            "Copied to this device for 5 minutes."
        case .generated:
            "A new password is ready."
        }
    }

    var systemImage: String {
        switch self {
        case .copied:
            "checkmark.circle.fill"
        case .generated:
            "arrow.clockwise.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .copied:
            .green
        case .generated:
            .accentColor
        }
    }
}

private struct ExportQualityRow: View {
    let quality: DocumentExportQuality
    let isSelected: Bool
    let sizeText: String?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(quality.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(quality.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)

                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)

                        Text("Calculating...")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                } else if let sizeText {
                    Text(sizeText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct DocumentPagePagerView: UIViewRepresentable {
    let pages: [DocumentPageSnapshot]
    @Binding var currentPageID: Int?
    let onSingleTap: () -> Void
    let onZoomStateChange: (Int, Bool) -> Void

    func makeUIView(context: Context) -> DocumentPagePagingView {
        DocumentPagePagingView()
    }

    func updateUIView(_ uiView: DocumentPagePagingView, context: Context) {
        let currentPageBinding = $currentPageID

        uiView.configure(
            pages: pages,
            currentPageID: currentPageBinding.wrappedValue,
            onPageChange: { pageID in
                currentPageBinding.wrappedValue = pageID
            },
            onSingleTap: onSingleTap,
            onZoomStateChange: onZoomStateChange
        )
    }
}

private final class DocumentPagePagingView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    private var pageViews: [DocumentPageHostView] = []
    private var pageIDs: [Int] = []
    private var currentPageID: Int?
    private var zoomedPageID: Int?
    private var lastLayoutSize: CGSize = .zero

    private var onPageChange: (Int) -> Void = { _ in }
    private var onSingleTap: () -> Void = {}
    private var onZoomStateChange: (Int, Bool) -> Void = { _, _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.size != .zero, bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        setCurrentPage(id: currentPageID ?? pageIDs.first, animated: false)
    }

    func configure(
        pages: [DocumentPageSnapshot],
        currentPageID: Int?,
        onPageChange: @escaping (Int) -> Void,
        onSingleTap: @escaping () -> Void,
        onZoomStateChange: @escaping (Int, Bool) -> Void
    ) {
        self.onPageChange = onPageChange
        self.onSingleTap = onSingleTap
        self.onZoomStateChange = onZoomStateChange

        syncPageViews(with: pages)
        setCurrentPage(id: currentPageID ?? pageIDs.first, animated: false)
        scrollView.isScrollEnabled = pages.count > 1 && zoomedPageID == nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let pageID = nearestPageID() else { return }
        guard currentPageID != pageID else { return }

        currentPageID = pageID
        onPageChange(pageID)
    }

    private func configureHierarchy() {
        backgroundColor = .black

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = .black

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 0
        stackView.alignment = .fill
        stackView.distribution = .fill

        addSubview(scrollView)
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func syncPageViews(with pages: [DocumentPageSnapshot]) {
        let newPageIDs = pages.map(\.id)

        if pageIDs != newPageIDs {
            rebuildPageViews(for: pages)
        }

        for (pageView, page) in zip(pageViews, pages) {
            pageView.configure(
                page: page,
                onSingleTap: onSingleTap,
                onZoomStateChange: { [weak self] isZoomed in
                    self?.handleZoomStateChange(for: page.id, isZoomed: isZoomed)
                }
            )
        }

        if !newPageIDs.contains(zoomedPageID ?? -1) {
            zoomedPageID = nil
        }

        pageIDs = newPageIDs
    }

    private func rebuildPageViews(for pages: [DocumentPageSnapshot]) {
        for pageView in pageViews {
            pageView.removeFromSuperview()
        }

        pageViews = pages.map { _ in
            let pageView = DocumentPageHostView()
            pageView.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(pageView)
            pageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor).isActive = true
            return pageView
        }
    }

    private func handleZoomStateChange(for pageID: Int, isZoomed: Bool) {
        if isZoomed {
            zoomedPageID = pageID
        } else if zoomedPageID == pageID {
            zoomedPageID = nil
        }

        scrollView.isScrollEnabled = pageIDs.count > 1 && zoomedPageID == nil
        onZoomStateChange(pageID, isZoomed)
    }

    private func setCurrentPage(id: Int?, animated: Bool) {
        guard let id, let index = pageIDs.firstIndex(of: id), scrollView.bounds.height > 0 else { return }

        currentPageID = id
        let targetOffset = CGPoint(x: 0, y: scrollView.bounds.height * CGFloat(index))

        guard scrollView.contentOffset != targetOffset else { return }
        scrollView.setContentOffset(targetOffset, animated: animated)
    }

    private func nearestPageID() -> Int? {
        guard !pageIDs.isEmpty, scrollView.bounds.height > 0 else { return nil }

        let rawIndex = Int(round(scrollView.contentOffset.y / scrollView.bounds.height))
        let clampedIndex = min(max(rawIndex, 0), pageIDs.count - 1)
        return pageIDs[clampedIndex]
    }
}

private final class DocumentPageHostView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let pageView = ZoomablePageContainerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    func configure(
        page: DocumentPageSnapshot,
        onSingleTap: @escaping () -> Void,
        onZoomStateChange: @escaping (Bool) -> Void
    ) {
        pageView.configure(
            image: page.image,
            pageInsets: UIEdgeInsets(top: 28, left: 20, bottom: 28, right: 20),
            onSingleTap: onSingleTap,
            onZoomStateChange: onZoomStateChange
        )
    }

    private func configureHierarchy() {
        backgroundColor = .black

        gradientLayer.colors = [
            UIColor.black.cgColor,
            UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1).cgColor,
            UIColor.black.cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradientLayer)

        pageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pageView)

        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: topAnchor),
            pageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class ZoomablePageContainerView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let pageCanvasView = UIView()
    private let imageView = UIImageView()
    private let pageBackgroundView = UIView()
    private var currentImageIdentifier: ObjectIdentifier?
    private var isZoomed = false
    private var pageInsets: UIEdgeInsets = .zero
    private let shadowPadding: CGFloat = 28

    private var onSingleTap: (() -> Void)?
    private var onZoomStateChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        image: UIImage,
        pageInsets: UIEdgeInsets,
        onSingleTap: @escaping () -> Void,
        onZoomStateChange: @escaping (Bool) -> Void
    ) {
        self.onSingleTap = onSingleTap
        self.onZoomStateChange = onZoomStateChange

        let identifier = ObjectIdentifier(image)
        var needsLayoutUpdate = false

        if self.pageInsets != pageInsets {
            self.pageInsets = pageInsets
            needsLayoutUpdate = true
        }

        if currentImageIdentifier != identifier {
            currentImageIdentifier = identifier
            imageView.image = image
            resetZoom(animated: false, notify: false)
            needsLayoutUpdate = true
        }

        if needsLayoutUpdate {
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        updateLayoutForCurrentBounds()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        pageCanvasView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentInsets()
        let hasZoom = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
        setZoomState(hasZoom)

        if !hasZoom {
            scheduleRecenterAtMinimumZoom()
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale <= scrollView.minimumZoomScale + 0.01 {
            scheduleRecenterAtMinimumZoom()
        }
    }

    private func configureHierarchy() {
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.bounces = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.isEnabled = false
        addSubview(scrollView)

        pageCanvasView.backgroundColor = .clear
        scrollView.addSubview(pageCanvasView)

        pageBackgroundView.backgroundColor = .white
        pageBackgroundView.layer.cornerRadius = 28
        pageBackgroundView.layer.cornerCurve = .continuous
        pageBackgroundView.layer.shadowColor = UIColor.black.cgColor
        pageBackgroundView.layer.shadowOpacity = 0.32
        pageBackgroundView.layer.shadowRadius = 24
        pageBackgroundView.layer.shadowOffset = CGSize(width: 0, height: 14)
        pageBackgroundView.clipsToBounds = false

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        pageBackgroundView.addSubview(imageView)
        pageCanvasView.addSubview(pageBackgroundView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        tapGesture.numberOfTapsRequired = 1
        scrollView.addGestureRecognizer(tapGesture)
    }

    private func updateLayoutForCurrentBounds() {
        guard bounds.width > 0, bounds.height > 0, let image = imageView.image else { return }

        let safeBounds = bounds.inset(by: pageInsets)
        let pageRect = AVMakeRect(
            aspectRatio: image.size,
            insideRect: safeBounds.insetBy(dx: shadowPadding, dy: shadowPadding)
        )
        let pageSize = CGSize(
            width: max(pageRect.width.rounded(.down), 1),
            height: max(pageRect.height.rounded(.down), 1)
        )
        let canvasSize = CGSize(
            width: pageSize.width + (shadowPadding * 2),
            height: pageSize.height + (shadowPadding * 2)
        )

        pageCanvasView.frame = CGRect(origin: .zero, size: canvasSize)
        pageBackgroundView.frame = CGRect(
            x: shadowPadding,
            y: shadowPadding,
            width: pageSize.width,
            height: pageSize.height
        )
        imageView.frame = pageBackgroundView.bounds
        scrollView.contentSize = canvasSize
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4

        if scrollView.zoomScale < scrollView.minimumZoomScale || !scrollView.zoomScale.isFinite {
            scrollView.zoomScale = scrollView.minimumZoomScale
        }

        if !isZoomed {
            resetZoom(animated: false, notify: false)
        } else {
            updateContentInsets()
        }
    }

    private func updateContentInsets() {
        let contentSize = scrollView.contentSize
        let inset = UIEdgeInsets(
            top: max((scrollView.bounds.height - contentSize.height) * 0.5, 0),
            left: max((scrollView.bounds.width - contentSize.width) * 0.5, 0),
            bottom: max((scrollView.bounds.height - contentSize.height) * 0.5, 0),
            right: max((scrollView.bounds.width - contentSize.width) * 0.5, 0)
        )

        if scrollView.contentInset != inset {
            scrollView.contentInset = inset
        }
    }

    private func resetZoom(animated: Bool, notify: Bool = true) {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
        scheduleRecenterAtMinimumZoom()
        scrollView.panGestureRecognizer.isEnabled = false
        if notify {
            setZoomState(false)
        } else {
            isZoomed = false
        }
    }

    private func scheduleRecenterAtMinimumZoom() {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }

        DispatchQueue.main.async { [weak self] in
            self?.recenterAtMinimumZoom()
        }
    }

    private func recenterAtMinimumZoom() {
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }

        updateContentInsets()
        let centeredOffset = CGPoint(
            x: -scrollView.contentInset.left,
            y: -scrollView.contentInset.top
        )

        if abs(scrollView.contentOffset.x - centeredOffset.x) > 0.5 || abs(scrollView.contentOffset.y - centeredOffset.y) > 0.5 {
            scrollView.setContentOffset(centeredOffset, animated: false)
        }
    }

    private func setZoomState(_ newValue: Bool) {
        guard isZoomed != newValue else { return }
        isZoomed = newValue
        scrollView.panGestureRecognizer.isEnabled = newValue
        onZoomStateChange?(newValue)
    }

    @objc
    private func handleSingleTap() {
        onSingleTap?()
    }
}

private enum DocumentPageRenderer {
    static func render(page: PDFPage) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let fallbackSize = CGSize(width: 1200, height: 1600)
        let pageSize = bounds.isEmpty ? fallbackSize : bounds.size
        let maxDimension: CGFloat = 2200
        let scale = maxDimension / max(pageSize.width, pageSize.height)
        let renderSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1

        return UIGraphicsImageRenderer(size: renderSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: renderSize))

            let cgContext = context.cgContext
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: renderSize.height)
            cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cgContext)
            cgContext.restoreGState()
        }
    }
}
