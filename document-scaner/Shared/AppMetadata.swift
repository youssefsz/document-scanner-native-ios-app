//
//  AppMetadata.swift
//  document-scaner
//
//

import Foundation

enum AppMetadata {
    static let creatorName = "Youssef Dhibi"
    static let portfolioDisplayName = "dhibi.tn"
    static let portfolioURL = URL(string: "https://dhibi.tn")!
    static let supportEmail = "dhibi.ywsf@gmail.com"
    static let legalEffectiveDate = "March 8, 2026"
    static let appStoreIDKey = "AppStoreID"

    static var appName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        return Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Document Scanner"
    }

    static var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    static var supportEmailURL: URL? {
        let diagnostics = SystemSupportDiagnosticsProvider().currentDiagnostics()
        let draft = SupportEmailDraftBuilder().makeDraft(topic: .generalFeedback, diagnostics: diagnostics)
        return draft.mailtoURL ?? URL(string: "mailto:\(supportEmail)")
    }

    static var supportDetails: String {
        SystemSupportDiagnosticsProvider().currentDiagnostics().formattedDetails
    }

    static var appStoreID: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: appStoreIDKey) as? String else {
            return nil
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    static var appStoreReviewURL: URL? {
        guard let appStoreID else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }
}
