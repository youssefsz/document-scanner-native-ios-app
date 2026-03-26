//
//  DocumentTitleFormatter.swift
//  document-scaner
//
//

import Foundation

enum DocumentTitleFormatter {
    nonisolated static func `default`(for date: Date) -> String {
        "Scan \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    nonisolated static func sanitized(_ proposedTitle: String?, fallbackDate: Date) -> String {
        let trimmedTitle = proposedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return trimmedTitle.isEmpty ? self.default(for: fallbackDate) : trimmedTitle
    }

    nonisolated static func exportFilenameBase(for title: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let sanitizedScalars = title.unicodeScalars.map { scalar in
            allowedScalars.contains(scalar) ? Character(scalar) : " "
        }
        let sanitizedTitle = String(sanitizedScalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        return sanitizedTitle.isEmpty ? "Document" : sanitizedTitle
    }

    nonisolated static func exportFilename(for title: String, quality: DocumentExportQuality) -> String {
        "\(exportFilenameBase(for: title)) - \(quality.title).pdf"
    }
}
