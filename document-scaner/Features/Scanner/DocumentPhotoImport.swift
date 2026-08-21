//
//  DocumentPhotoImport.swift
//  document-scaner
//

import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhotoImportProgress: Equatable, Sendable {
    let currentPhoto: Int
    let totalPhotos: Int

    var detailText: String {
        totalPhotos == 1 ? "Preparing selected photo" : "Photo \(currentPhoto) of \(totalPhotos)"
    }

    var accessibilityLabel: String {
        totalPhotos == 1 ? "Loading selected photo" : "Loading photo \(currentPhoto) of \(totalPhotos)"
    }
}

enum DocumentPhotoImportError: LocalizedError, Equatable, Sendable {
    case couldNotLoadPhoto(position: Int)

    var errorDescription: String? {
        switch self {
        case .couldNotLoadPhoto(let position):
            "Photo \(position) could not be loaded. If it is stored in iCloud, check your connection and try again."
        }
    }
}

@MainActor
enum OrderedPhotoImportLoader {
    static func load<Selection>(
        _ selections: [Selection],
        onProgress: (PhotoImportProgress) -> Void,
        loadPhoto: (Selection) async throws -> UIImage?
    ) async throws -> [UIImage] {
        var pages: [UIImage] = []
        pages.reserveCapacity(selections.count)

        for (index, selection) in selections.enumerated() {
            try Task.checkCancellation()
            onProgress(
                PhotoImportProgress(
                    currentPhoto: index + 1,
                    totalPhotos: selections.count
                )
            )

            do {
                guard let image = try await loadPhoto(selection) else {
                    throw DocumentPhotoImportError.couldNotLoadPhoto(position: index + 1)
                }
                pages.append(image)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DocumentPhotoImportError {
                throw error
            } catch {
                throw DocumentPhotoImportError.couldNotLoadPhoto(position: index + 1)
            }
        }

        return pages
    }
}

struct PhotoImportProgressOverlay: View {
    let progress: PhotoImportProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)

                Text("Loading Photos…")
                    .font(.headline)

                Text(progress.detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
        .transition(.opacity)
    }
}

extension View {
    func documentPhotoImporter(
        isPresented: Binding<Bool>,
        progress: Binding<PhotoImportProgress?>,
        onComplete: @escaping ([UIImage]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> some View {
        modifier(
            DocumentPhotoImportModifier(
                isPresented: isPresented,
                progress: progress,
                onComplete: onComplete,
                onError: onError
            )
        )
    }
}

private struct DocumentPhotoImportModifier: ViewModifier {
    private static let maximumPageCount = 20

    @Binding var isPresented: Bool
    @Binding var progress: PhotoImportProgress?
    let onComplete: ([UIImage]) -> Void
    let onError: (Error) -> Void

    @State private var selection: [PhotosPickerItem] = []
    @State private var loadingTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $isPresented,
                selection: $selection,
                maxSelectionCount: Self.maximumPageCount,
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: selection) { selectedItems in
                load(selectedItems)
            }
            .onDisappear {
                loadingTask?.cancel()
                loadingTask = nil
                progress = nil
            }
    }

    private func load(_ selectedItems: [PhotosPickerItem]) {
        guard !selectedItems.isEmpty else { return }

        loadingTask?.cancel()
        loadingTask = Task { @MainActor in
            defer {
                selection = []
                progress = nil
                loadingTask = nil
            }

            do {
                let pages = try await OrderedPhotoImportLoader.load(
                    selectedItems,
                    onProgress: { progress = $0 },
                    loadPhoto: { item in
                        try await item.loadTransferable(type: ImportedDocumentPhoto.self)?.image
                    }
                )
                try Task.checkCancellation()
                onComplete(pages)
            } catch is CancellationError {
                return
            } catch {
                onError(error)
            }
        }
    }
}

private struct ImportedDocumentPhoto: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let image = UIImage(data: data) else {
                throw ImportedDocumentPhotoError.invalidImageData
            }
            return ImportedDocumentPhoto(image: image)
        }
    }
}

private enum ImportedDocumentPhotoError: Error {
    case invalidImageData
}
