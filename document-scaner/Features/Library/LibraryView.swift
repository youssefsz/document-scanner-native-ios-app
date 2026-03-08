//
//  LibraryView.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import SwiftUI
import VisionKit

struct LibraryView: View {
    @EnvironmentObject private var library: DocumentLibrary

    @AppStorage(AppPreferenceKey.documentSortOrder) private var documentSortOrder = DocumentSortOrder.newestFirst.rawValue
    @State private var isScannerPresented = false

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
                                        NavigationLink {
                                            DocumentDetailView(document: document)
                                        } label: {
                                            DocumentCard(document: document)
                                                .frame(width: cardWidth, height: DocumentCardLayout.totalCardHeight)
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: cardWidth, height: DocumentCardLayout.totalCardHeight)
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
                .navigationTitle("Documents")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    floatingScanButton
                }
            }
        }
        .task {
            await library.loadIfNeeded()
        }
        .sheet(isPresented: $isScannerPresented) {
            DocumentScannerSheet(
                onComplete: { pages in
                    isScannerPresented = false
                    Task {
                        await library.importScan(pages: pages)
                    }
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
        .alert("Something Went Wrong", isPresented: activeErrorBinding) {
            Button("OK", role: .cancel) {
                library.activeError = nil
            }
        } message: {
            Text(library.activeError?.message ?? "Unknown error")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Documents Yet",
            systemImage: "doc.viewfinder",
            description: Text("Scan paper documents and the app will save them as PDFs in a local library.")
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
        .buttonStyle(.glassProminent)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private func openScanner() {
        guard DocumentScannerSheet.isSupported else {
            library.activeError = LibraryError(message: "Document scanning requires a physical iPhone or iPad with camera access.")
            return
        }

        isScannerPresented = true
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
}

#Preview {
    LibraryView()
        .environmentObject(DocumentLibrary.preview)
}
