//
//  AppPreferences.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import Foundation

enum AppPreferenceKey {
    static let documentSortOrder = "documentSortOrder"
    static let confirmBeforeDelete = "confirmBeforeDelete"
    static let useDarkMode = "useDarkMode"
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
