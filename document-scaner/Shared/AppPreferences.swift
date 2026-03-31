//
//  AppPreferences.swift
//  document-scaner
//
//

import Foundation

enum AppPreferenceKey {
    nonisolated static let documentSortOrder = "documentSortOrder"
    nonisolated static let defaultExportQuality = "defaultExportQuality"
    nonisolated static let confirmBeforeDelete = "confirmBeforeDelete"
    nonisolated static let useDarkMode = "useDarkMode"
    nonisolated static let ocrAutoDetectLanguage = "ocrAutoDetectLanguage"
    nonisolated static let ocrPreferredLanguages = "ocrPreferredLanguages"
    nonisolated static let hasCreatedFirstDocument = "hasCreatedFirstDocument"
    nonisolated static let pendingReviewDocumentID = "pendingReviewDocumentID"
    nonisolated static let hasRequestedNativeReview = "hasRequestedNativeReview"
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
