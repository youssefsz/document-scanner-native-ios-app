//
//  DocumentExportQuality.swift
//  document-scaner
//
//

import Foundation

enum DocumentExportQuality: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case veryHigh

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .veryHigh:
            "Very High"
        }
    }

    nonisolated var summary: String {
        switch self {
        case .low:
            "Smallest file size for email and quick uploads."
        case .medium:
            "Balanced size and readability for most documents."
        case .high:
            "Sharper text and details with moderate compression."
        case .veryHigh:
            "Best detail with the largest shared file size."
        }
    }

    nonisolated var maxPageDimension: CGFloat {
        switch self {
        case .low:
            1_280
        case .medium:
            1_720
        case .high:
            2_240
        case .veryHigh:
            3_000
        }
    }

    nonisolated var jpegCompressionQuality: CGFloat {
        switch self {
        case .low:
            0.5
        case .medium:
            0.64
        case .high:
            0.76
        case .veryHigh:
            0.88
        }
    }
}
