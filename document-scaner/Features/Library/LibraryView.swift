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

    private let columns = [
        GridItem(.flexible(), spacing: 20, alignment: .top),
        GridItem(.flexible(), spacing: 20, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if displayedDocuments.isEmpty, !library.isLoading {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                        .padding(.horizontal, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(displayedDocuments) { document in
                            NavigationLink {
                                DocumentDetailView(document: document)
                            } label: {
                                DocumentCard(document: document)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
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
            .overlay {
                if library.isLoading, library.documents.isEmpty {
                    ProgressView("Loading Documents")
                }
            }
            .overlay(alignment: .bottom) {
                floatingScanButton
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
}

#Preview {
    LibraryView()
        .environmentObject(DocumentLibrary.preview)
}
