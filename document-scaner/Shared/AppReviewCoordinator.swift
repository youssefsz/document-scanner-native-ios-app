//
//  AppReviewCoordinator.swift
//  document-scaner
//
//  Created by Codex on 8/3/2026.
//

import Foundation

enum AppReviewCoordinator {
    static func registerExistingLibraryIfNeeded(_ documents: [ScannedDocument], defaults: UserDefaults = .standard) {
        guard !documents.isEmpty else { return }
        guard !defaults.bool(forKey: AppPreferenceKey.hasCreatedFirstDocument) else { return }

        defaults.set(true, forKey: AppPreferenceKey.hasCreatedFirstDocument)
    }

    static func armFirstDocumentReviewIfNeeded(
        existingDocumentCount: Int,
        updatedDocuments: [ScannedDocument],
        defaults: UserDefaults = .standard
    ) {
        guard existingDocumentCount == 0 else { return }
        guard !defaults.bool(forKey: AppPreferenceKey.hasCreatedFirstDocument) else { return }
        guard let firstDocument = updatedDocuments.first else { return }

        defaults.set(true, forKey: AppPreferenceKey.hasCreatedFirstDocument)
        defaults.set(firstDocument.id.uuidString, forKey: AppPreferenceKey.pendingReviewDocumentID)
    }

    static func consumePendingReviewRequest(for document: ScannedDocument, defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: AppPreferenceKey.hasRequestedNativeReview) else { return false }
        guard defaults.string(forKey: AppPreferenceKey.pendingReviewDocumentID) == document.id.uuidString else { return false }

        defaults.set(true, forKey: AppPreferenceKey.hasRequestedNativeReview)
        defaults.removeObject(forKey: AppPreferenceKey.pendingReviewDocumentID)
        return true
    }
}
