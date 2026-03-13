//
//  AppPreferences.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import Foundation

enum AppPreferenceKey {
    static let documentSortOrder = "documentSortOrder"
    static let defaultExportQuality = "defaultExportQuality"
    static let confirmBeforeDelete = "confirmBeforeDelete"
    static let useDarkMode = "useDarkMode"
    static let hasCreatedFirstDocument = "hasCreatedFirstDocument"
    static let pendingReviewDocumentID = "pendingReviewDocumentID"
    static let hasRequestedNativeReview = "hasRequestedNativeReview"
}

enum DocumentSortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst:
            "Newest First"
        case .oldestFirst:
            "Oldest First"
        }
    }
}
