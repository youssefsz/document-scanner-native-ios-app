//
//  AppMetadata.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import Foundation

enum AppMetadata {
    static let creatorName = "Youssef Dhibi"
    static let portfolioDisplayName = "dhibi.tn"
    static let portfolioURL = URL(string: "https://dhibi.tn")!
    static let supportEmail = "dhibi.ywsf@gmail.com"
    static let legalEffectiveDate = "March 8, 2026"

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

    static var supportEmailURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "\(appName) Support"),
            URLQueryItem(
                name: "body",
                value: """
                Hello \(creatorName),

                I need help with \(appName).

                \(supportDetails)

                Please describe the issue:
                """
            )
        ]

        return components.url!
    }

    static var supportDetails: String {
        """
        \(appName)
        \(versionDescription)
        iOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
    }
}
