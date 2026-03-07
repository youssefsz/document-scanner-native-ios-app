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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PDFPreview(url: document.pdfURL)
                    .frame(minHeight: 520)
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
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actionBar
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

    private var actionBar: some View {
        HStack(spacing: 12) {
            ShareLink(item: document.pdfURL) {
                Label("Share PDF", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)

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
}

private struct PDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(true, withViewOptions: nil)
        view.backgroundColor = .secondarySystemGroupedBackground
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = PDFDocument(url: url)
    }
}
