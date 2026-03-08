//
//  DocumentDetailView.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import PDFKit
import SwiftUI

struct DocumentDetailView: View {
    let document: ScannedDocument

    @AppStorage(AppPreferenceKey.confirmBeforeDelete) private var confirmBeforeDelete = true
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: DocumentLibrary

    @State private var isShowingDeleteConfirmation = false
    @State private var isLoadingPreview = true
    @State private var pdfDocument: PDFDocument?
    @State private var previewErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            previewSection
                .frame(maxWidth: .infinity)
                .frame(minHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 12) {
                Text(document.title)
                    .font(.title2.weight(.semibold))

                Label(document.createdAt.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                    .foregroundStyle(.secondary)

                Label("\(document.pageCount) scanned page\(document.pageCount == 1 ? "" : "s")", systemImage: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .task(id: document.id) {
            loadPDF()
        }
        .confirmationDialog("Delete this document?", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Document", role: .destructive) {
                Task {
                    await library.delete(document)
                    dismiss()
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved PDF and preview from local storage.")
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if isLoadingPreview {
            DocumentPreviewSkeleton()
        } else if let pdfDocument {
            PDFPreview(document: pdfDocument)
                .background(Color(.secondarySystemGroupedBackground))
        } else {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "doc.text.magnifyingglass",
                description: Text(previewErrorMessage ?? "The saved PDF could not be loaded.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemGroupedBackground))
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if pdfDocument != nil {
                ShareLink(item: document.pdfURL) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            } else {
                Label("Share PDF", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(.secondary)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    }
            }

            Button(role: .destructive) {
                if confirmBeforeDelete {
                    isShowingDeleteConfirmation = true
                } else {
                    deleteDocument()
                }
            } label: {
                Label("Delete", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.bar)
    }

    private func deleteDocument() {
        Task {
            await library.delete(document)
            dismiss()
        }
    }

    private func loadPDF() {
        isLoadingPreview = true

        let url = document.pdfURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            pdfDocument = nil
            previewErrorMessage = "The PDF file is missing from local storage."
            isLoadingPreview = false
            return
        }

        guard let loadedDocument = PDFDocument(url: url), loadedDocument.pageCount > 0 else {
            pdfDocument = nil
            previewErrorMessage = "The PDF file exists, but the app could not read it."
            isLoadingPreview = false
            return
        }

        pdfDocument = loadedDocument
        previewErrorMessage = nil
        isLoadingPreview = false
    }
}

private struct PDFPreview: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemGroupedBackground
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = document
    }
}
