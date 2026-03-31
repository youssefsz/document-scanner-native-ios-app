//
//  OCRPreferences.swift
//  document-scaner
//
//

import Foundation
import Vision

struct OCRLanguageOption: Identifiable, Hashable {
    let code: String
    let displayName: String

    var id: String { code }
}

struct OCRRequestConfiguration: Sendable {
    let preferredLanguageCodes: [String]
    let automaticallyDetectsLanguage: Bool
    let requestRevision: Int
}

enum OCRPreferences {
    nonisolated static let defaultFallbackLanguageCodes = ["en-US", "fr-FR"]
    nonisolated static let pinnedRequestRevision = VNRecognizeTextRequestRevision3

    nonisolated static func availableLanguageOptions() -> [OCRLanguageOption] {
        let locale = Locale.current

        return supportedRecognitionLanguageCodes().map { code in
            OCRLanguageOption(
                code: code,
                displayName: locale.localizedString(forIdentifier: code) ?? code
            )
        }
    }

    nonisolated static func supportedRecognitionLanguageCodes() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = pinnedRevision(in: VNRecognizeTextRequest.supportedRevisions)

        let supported = (try? request.supportedRecognitionLanguages()) ?? defaultFallbackLanguageCodes
        return uniqueLanguageCodes(from: supported)
    }

    nonisolated static func storedAutoDetectLanguage(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: AppPreferenceKey.ocrAutoDetectLanguage) as? Bool ?? true
    }

    nonisolated static func setStoredAutoDetectLanguage(_ newValue: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(newValue, forKey: AppPreferenceKey.ocrAutoDetectLanguage)
    }

    nonisolated static func storedPreferredLanguageCodes(userDefaults: UserDefaults = .standard) -> [String] {
        if let data = userDefaults.data(forKey: AppPreferenceKey.ocrPreferredLanguages),
           let codes = try? JSONDecoder().decode([String].self, from: data) {
            let filteredCodes = intersectWithSupportedLanguages(codes)
            if !filteredCodes.isEmpty {
                return filteredCodes
            }
        }

        let seededCodes = seededPreferredLanguageCodes()
        setStoredPreferredLanguageCodes(seededCodes, userDefaults: userDefaults)
        return seededCodes
    }

    nonisolated static func setStoredPreferredLanguageCodes(_ codes: [String], userDefaults: UserDefaults = .standard) {
        let filteredCodes = intersectWithSupportedLanguages(codes)
        let data = try? JSONEncoder().encode(filteredCodes)
        userDefaults.set(data, forKey: AppPreferenceKey.ocrPreferredLanguages)
    }

    nonisolated static func currentRequestConfiguration(userDefaults: UserDefaults = .standard) -> OCRRequestConfiguration {
        let supportedCodes = supportedRecognitionLanguageCodes()
        let storedCodes = storedPreferredLanguageCodes(userDefaults: userDefaults)
        let explicitCodes = intersectWithSupportedLanguages(storedCodes, supportedCodes: supportedCodes)
        let seededCodes = intersectWithSupportedLanguages(seededPreferredLanguageCodes(), supportedCodes: supportedCodes)
        let preferredCodes = explicitCodes.isEmpty ? seededCodes : explicitCodes
        let autoDetectLanguage = storedAutoDetectLanguage(userDefaults: userDefaults)
        let canAutoDetectLanguage = pinnedRequestRevision >= VNRecognizeTextRequestRevision3

        return OCRRequestConfiguration(
            preferredLanguageCodes: preferredCodes,
            automaticallyDetectsLanguage: autoDetectLanguage && canAutoDetectLanguage,
            requestRevision: pinnedRevision(in: VNRecognizeTextRequest.supportedRevisions)
        )
    }

    nonisolated static func seededPreferredLanguageCodes() -> [String] {
        let supportedCodes = supportedRecognitionLanguageCodes()
        var seeded: [String] = []

        for identifier in Locale.preferredLanguages + defaultFallbackLanguageCodes {
            if let supportedIdentifier = bestSupportedLanguage(for: identifier, supportedCodes: supportedCodes) {
                seeded.append(supportedIdentifier)
            }
        }

        return uniqueLanguageCodes(from: seeded)
    }

    nonisolated static func intersectWithSupportedLanguages(_ codes: [String], supportedCodes: [String]? = nil) -> [String] {
        let supported = supportedCodes ?? supportedRecognitionLanguageCodes()
        let matchedCodes = codes.compactMap { bestSupportedLanguage(for: $0, supportedCodes: supported) }
        return uniqueLanguageCodes(from: matchedCodes)
    }

    nonisolated static func pinnedRevision(in supportedRevisions: IndexSet) -> Int {
        if supportedRevisions.contains(pinnedRequestRevision) {
            return pinnedRequestRevision
        }

        return supportedRevisions.last ?? pinnedRequestRevision
    }

    nonisolated private static func bestSupportedLanguage(for identifier: String, supportedCodes: [String]) -> String? {
        if supportedCodes.contains(identifier) {
            return identifier
        }

        let baseIdentifier = baseLanguageIdentifier(for: identifier)
        return supportedCodes.first { baseLanguageIdentifier(for: $0) == baseIdentifier }
    }

    nonisolated private static func baseLanguageIdentifier(for identifier: String) -> String {
        let normalizedIdentifier = identifier.replacingOccurrences(of: "_", with: "-")
        return normalizedIdentifier.split(separator: "-").first.map(String.init)?.lowercased() ?? normalizedIdentifier.lowercased()
    }

    nonisolated private static func uniqueLanguageCodes(from identifiers: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for identifier in identifiers where seen.insert(identifier).inserted {
            result.append(identifier)
        }

        return result
    }
}
