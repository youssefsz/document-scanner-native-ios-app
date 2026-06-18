//
//  SupportFeedbackService.swift
//  document-scaner
//

import Foundation
import MessageUI
import UIKit

enum SupportTopic: String, CaseIterable, Identifiable {
    case bugReport
    case contentIssue
    case featureSuggestion
    case technicalSupport
    case generalFeedback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bugReport:
            "Bug Report"
        case .contentIssue:
            "Content Issue"
        case .featureSuggestion:
            "Feature Suggestion"
        case .technicalSupport:
            "Technical Support"
        case .generalFeedback:
            "General Feedback"
        }
    }

    var subtitle: String {
        switch self {
        case .bugReport:
            "Something is broken or not behaving correctly."
        case .contentIssue:
            "OCR output or generated document content looks incorrect."
        case .featureSuggestion:
            "Suggest a new capability or workflow improvement."
        case .technicalSupport:
            "Get help with scanning, camera access, storage, PDF export, or sharing."
        case .generalFeedback:
            "Share anything else with the Document Scanner team."
        }
    }

    var systemImage: String {
        switch self {
        case .bugReport:
            "ladybug"
        case .contentIssue:
            "doc.text.magnifyingglass"
        case .featureSuggestion:
            "lightbulb"
        case .technicalSupport:
            "wrench.and.screwdriver"
        case .generalFeedback:
            "bubble.left.and.bubble.right"
        }
    }
}

struct SupportDiagnostics: Equatable {
    let appName: String
    let appVersion: String
    let buildNumber: String
    let systemName: String
    let systemVersion: String
    let deviceModel: String
    let hardwareModel: String
    let preferredLocale: String

    var formattedDetails: String {
        """
        App: \(appName)
        App Version: \(appVersion)
        Build Number: \(buildNumber)
        System: \(systemName) \(systemVersion)
        Device Model: \(deviceModel)
        Hardware Model: \(hardwareModel)
        Preferred Locale: \(preferredLocale)
        """
    }
}

protocol SupportDiagnosticsProviding {
    func currentDiagnostics() -> SupportDiagnostics
}

struct SupportDiagnosticsEnvironment {
    var appName: () -> String
    var appVersion: () -> String
    var buildNumber: () -> String
    var systemName: () -> String
    var systemVersion: () -> String
    var deviceModel: () -> String
    var hardwareModel: () -> String
    var preferredLocale: () -> String

    static func system(
        bundle: Bundle = .main,
        device: UIDevice = .current
    ) -> SupportDiagnosticsEnvironment {
        SupportDiagnosticsEnvironment(
            appName: {
                if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                   !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return displayName
                }

                return bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Document Scanner"
            },
            appVersion: {
                bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unavailable"
            },
            buildNumber: {
                bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unavailable"
            },
            systemName: {
                device.systemName
            },
            systemVersion: {
                device.systemVersion
            },
            deviceModel: {
                device.localizedModel
            },
            hardwareModel: {
                HardwareModelIdentifier.current
            },
            preferredLocale: {
                Locale.preferredLanguages.first ?? Locale.current.identifier
            }
        )
    }
}

struct SystemSupportDiagnosticsProvider: SupportDiagnosticsProviding {
    private let environment: SupportDiagnosticsEnvironment

    init(environment: SupportDiagnosticsEnvironment = .system()) {
        self.environment = environment
    }

    func currentDiagnostics() -> SupportDiagnostics {
        SupportDiagnostics(
            appName: normalized(environment.appName()),
            appVersion: normalized(environment.appVersion()),
            buildNumber: normalized(environment.buildNumber()),
            systemName: normalized(environment.systemName()),
            systemVersion: normalized(environment.systemVersion()),
            deviceModel: normalized(environment.deviceModel()),
            hardwareModel: normalized(environment.hardwareModel()),
            preferredLocale: normalized(environment.preferredLocale())
        )
    }

    private func normalized(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? "Unavailable" : trimmedValue
    }
}

private enum HardwareModelIdentifier {
    static var current: String {
        #if targetEnvironment(simulator)
        if let simulatorIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulatorIdentifier.isEmpty {
            return "\(simulatorIdentifier) Simulator"
        }
        #endif

        var systemInfo = utsname()
        uname(&systemInfo)

        let identifier = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { reboundPointer in
                String(validatingUTF8: reboundPointer)
            }
        }

        return identifier ?? "Unavailable"
    }
}

struct SupportEmailDraft: Identifiable, Equatable {
    let id = UUID()
    let recipient: String
    let subject: String
    let body: String

    static func == (lhs: SupportEmailDraft, rhs: SupportEmailDraft) -> Bool {
        lhs.recipient == rhs.recipient &&
            lhs.subject == rhs.subject &&
            lhs.body == rhs.body
    }

    var mailtoURL: URL? {
        guard !recipient.isEmpty,
              let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .supportQueryValueAllowed),
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .supportQueryValueAllowed) else {
            return nil
        }

        return URL(string: "mailto:\(recipient)?subject=\(encodedSubject)&body=\(encodedBody)")
    }
}

protocol SupportEmailDraftBuilding {
    func makeDraft(topic: SupportTopic, diagnostics: SupportDiagnostics) -> SupportEmailDraft
}

struct SupportEmailDraftBuilder: SupportEmailDraftBuilding {
    let recipient: String

    init(recipient: String = AppMetadata.supportEmail) {
        self.recipient = recipient
    }

    func makeDraft(topic: SupportTopic, diagnostics: SupportDiagnostics) -> SupportEmailDraft {
        SupportEmailDraft(
            recipient: recipient,
            subject: "\(diagnostics.appName) Support - \(topic.title)",
            body: """
            Hello \(diagnostics.appName) Support,

            Request Type: \(topic.title)

            \(diagnostics.formattedDetails)

            --------------------
            Message:

            Please describe the issue here.
            """
        )
    }
}

enum SupportEmailRoute: Equatable {
    case nativeComposer
    case external(URL)
    case unavailable
}

struct SupportEmailRouter {
    let canSendMail: Bool

    init(canSendMail: Bool) {
        self.canSendMail = canSendMail
    }

    func route(for draft: SupportEmailDraft) -> SupportEmailRoute {
        if canSendMail {
            return .nativeComposer
        }

        guard let fallbackURL = draft.mailtoURL else {
            return .unavailable
        }

        return .external(fallbackURL)
    }
}

private extension CharacterSet {
    static let supportQueryValueAllowed: CharacterSet = {
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: "&+=?#")
        return allowedCharacters
    }()
}
