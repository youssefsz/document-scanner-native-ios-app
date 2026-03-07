//
//  AppMetadata.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import Foundation

enum AppMetadata {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Document Scanner"
    }

    static var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    static var supportDetails: String {
        """
        \(appName)
        \(versionDescription)
        iOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
    }
}
