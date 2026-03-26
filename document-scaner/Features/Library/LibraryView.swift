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

    @AppStorage(AppPreferenceKey.documentSortOrder) private var documentSortOrder = DocumentSortOrder.newestFirst.rawValue
    @AppStorage(AppPreferenceKey.hasCreatedFirstDocument) private var hasCreatedFirstDocument = false
    @State private var isScannerPresented = false
    @State private var isSavingPendingScan = false
    @State private var isDeletingSelection = false
    @State private var isNamingPendingScan = false
    @State private var isSelectionMode = false
    @State private var isShowingDeleteConfirmation = false
    @State private var pendingScanPages: [UIImage] = []
    @State private var pendingScanTitle = ""
    @State private var selectedDocument: ScannedDocument?
    @State private var selectedDocumentIDs: Set<ScannedDocument.ID> = []

    private let gridSpacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 16

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let cardWidth = floor((proxy.size.width - (horizontalPadding * 2) - gridSpacing) / 2)

                ScrollView {
                    if library.isLoading, library.documents.isEmpty {
                        LibraryLoadingSkeletonView(cardWidth: cardWidth, spacing: gridSpacing)
                    } else if displayedDocuments.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                            .padding(.horizontal, 24)
                    } else {
                        VStack(spacing: gridSpacing) {
                            ForEach(Array(documentRows.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .top, spacing: gridSpacing) {
                                    ForEach(row) { document in
                                        LibraryDocumentTile(
                                            document: document,
                                            cardWidth: cardWidth,
                                            isSelectionMode: isSelectionMode,
                                            isSelected: selectedDocumentIDs.contains(document.id),
                                            onTap: {
                                                handlePrimaryAction(for: document)
                                            },
                                            onLongPress: {
                                                handleLongPress(on: document)
                                            }
                                        )
                                    }

                                    if row.count == 1 {
                                        Color.clear
                                            .frame(width: cardWidth, height: DocumentCardLayout.totalCardHeight)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 20)
                        .padding(.bottom, 140)
                    }
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle(isSelectionMode ? selectionTitle : "Documents")
                .navigationBarTitleDisplayMode(isSelectionMode ? .inline : .large)
                .toolbar {
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
                        ToolbarItem(placement: .navigationBarTrailing) {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    bottomAccessory
                }
                .overlay {
                    if isDeletingSelection {
                        deletionOverlay
                    }
                }
            }
        }
        .animation(selectionAnimation, value: isSelectionMode)
        .animation(selectionAnimation, value: selectedDocumentIDs)
        .task {
            await library.loadIfNeeded()
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
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var bottomAccessory: some View {
        Group {
            if isSelectionMode {
                LibrarySelectionBar(
                    selectionCount: selectedDocumentIDs.count,
                    isDeleting: isDeletingSelection,
                    deleteAction: {
                        isShowingDeleteConfirmation = true
                    }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                floatingScanButton
            }
        }
    }

    private var deletionOverlay: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            ProgressView("Deleting documents...")
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .transition(.opacity)
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
        let existingDocumentCount = library.documents.count

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
        let selectedOrder = DocumentSortOrder(rawValue: documentSortOrder) ?? .newestFirst

        switch selectedOrder {
        case .newestFirst:
            return library.documents.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            return library.documents.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private var documentRows: [[ScannedDocument]] {
        stride(from: 0, to: displayedDocuments.count, by: 2).map { index in
            Array(displayedDocuments[index..<min(index + 2, displayedDocuments.count)])
        }
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

private struct LibraryDocumentTile: View {
    let document: ScannedDocument
    let cardWidth: CGFloat
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
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectionCount == 1 ? "1 document selected" : "\(selectionCount) documents selected")
                    .font(.headline.weight(.semibold))

                Text("Tap more cards or delete the current selection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button(action: deleteAction) {
                Group {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.regular)
                            .frame(width: 24, height: 24)
                    } else {
                        Label("Delete", systemImage: "trash")
                            .font(.headline)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .appProminentButtonStyle(color: .red)
            .disabled(selectionCount == 0 || isDeleting)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
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
