//
//  DocumentLibrary.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import Combine
import SwiftUI
import UIKit

@MainActor
final class DocumentLibrary: ObservableObject {
    @Published private(set) var documents: [ScannedDocument] = []
    @Published private(set) var isLoading = false
    @Published var activeError: LibraryError?

    private let store: DocumentStore
    private var hasLoaded = false

    init(store: DocumentStore = DocumentStore()) {
        self.store = store
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        do {
            documents = try await store.loadDocuments()
            hasLoaded = true
            activeError = nil
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
        }
    }

    func importScan(pages: [UIImage]) async {
        isLoading = true
        defer { isLoading = false }

        do {
            documents = try await store.saveScan(pages: pages)
            hasLoaded = true
            activeError = nil
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
        }
    }

    func delete(_ document: ScannedDocument) async {
        await delete([document])
    }

    func delete(_ documents: [ScannedDocument]) async {
        guard !documents.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            self.documents = try await store.delete(documents)
            activeError = nil
        } catch {
            activeError = LibraryError(message: error.localizedDescription)
        }
    }

    static let preview: DocumentLibrary = {
        let library = DocumentLibrary(store: DocumentStore())
        library.documents = [ScannedDocument.previewDocument]
        library.hasLoaded = true
        return library
    }()
}

struct LibraryError: Identifiable {
    let id = UUID()
    let message: String
}
