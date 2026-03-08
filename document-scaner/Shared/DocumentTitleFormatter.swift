//
//  DocumentTitleFormatter.swift
//  document-scaner
//
//  Created by Codex on 8/3/2026.
//

import Foundation

enum DocumentTitleFormatter {
    static func `default`(for date: Date) -> String {
        "Scan \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func sanitized(_ proposedTitle: String?, fallbackDate: Date) -> String {
        let trimmedTitle = proposedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return trimmedTitle.isEmpty ? self.default(for: fallbackDate) : trimmedTitle
    }
}
