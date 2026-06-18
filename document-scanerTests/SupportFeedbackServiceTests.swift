import MessageUI
import XCTest
@testable import DocScanner

@MainActor
final class SupportFeedbackServiceTests: XCTestCase {
    func testSupportTopicsExposeFiveOrderedCasesWithStableMetadata() {
        XCTAssertEqual(
            SupportTopic.allCases,
            [.bugReport, .contentIssue, .featureSuggestion, .technicalSupport, .generalFeedback]
        )

        let metadata = SupportTopic.allCases.map {
            SupportTopicMetadata(id: $0.id, title: $0.title, subtitle: $0.subtitle, systemImage: $0.systemImage)
        }
        XCTAssertEqual(
            metadata,
            [
                SupportTopicMetadata(id: "bugReport", title: "Bug Report", subtitle: "Something is broken or not behaving correctly.", systemImage: "ladybug"),
                SupportTopicMetadata(id: "contentIssue", title: "Content Issue", subtitle: "OCR output or generated document content looks incorrect.", systemImage: "doc.text.magnifyingglass"),
                SupportTopicMetadata(id: "featureSuggestion", title: "Feature Suggestion", subtitle: "Suggest a new capability or workflow improvement.", systemImage: "lightbulb"),
                SupportTopicMetadata(id: "technicalSupport", title: "Technical Support", subtitle: "Get help with scanning, camera access, storage, PDF export, or sharing.", systemImage: "wrench.and.screwdriver"),
                SupportTopicMetadata(id: "generalFeedback", title: "General Feedback", subtitle: "Share anything else with the Document Scanner team.", systemImage: "bubble.left.and.bubble.right"),
            ]
        )
    }

    func testDiagnosticsProviderNormalizesMissingValuesToUnavailable() {
        let provider = SystemSupportDiagnosticsProvider(
            environment: SupportDiagnosticsEnvironment(
                appName: { "" },
                appVersion: { " " },
                buildNumber: { "" },
                systemName: { "" },
                systemVersion: { "" },
                deviceModel: { "" },
                hardwareModel: { "" },
                preferredLocale: { "" }
            )
        )

        XCTAssertEqual(
            provider.currentDiagnostics(),
            SupportDiagnostics(
                appName: "Unavailable",
                appVersion: "Unavailable",
                buildNumber: "Unavailable",
                systemName: "Unavailable",
                systemVersion: "Unavailable",
                deviceModel: "Unavailable",
                hardwareModel: "Unavailable",
                preferredLocale: "Unavailable"
            )
        )
    }

    func testFormattedDetailsContainsExpectedSafeFieldsOnly() {
        let diagnostics = makeDiagnostics()

        XCTAssertEqual(
            diagnostics.formattedDetails,
            """
            App: Document Scanner
            App Version: 1.0.5
            Build Number: 1
            System: iOS 26.5
            Device Model: iPhone
            Hardware Model: iPhone17,1
            Preferred Locale: en_TN
            """
        )

        XCTAssertFalse(diagnostics.formattedDetails.contains("identifier"))
        XCTAssertFalse(diagnostics.formattedDetails.contains("hostname"))
        XCTAssertFalse(diagnostics.formattedDetails.contains("serial"))
        XCTAssertFalse(diagnostics.formattedDetails.contains("Vendor"))
    }

    func testDraftBuilderIncludesDiagnosticsBlockForEveryTopic() {
        let diagnostics = makeDiagnostics()
        let builder = SupportEmailDraftBuilder(recipient: "dhibi.ywsf@gmail.com")

        for topic in SupportTopic.allCases {
            let draft = builder.makeDraft(topic: topic, diagnostics: diagnostics)

            XCTAssertEqual(draft.recipient, "dhibi.ywsf@gmail.com")
            XCTAssertEqual(draft.subject, "Document Scanner Support - \(topic.title)")
            XCTAssertTrue(draft.body.contains("Hello Document Scanner Support,"))
            XCTAssertTrue(draft.body.contains("Request Type: \(topic.title)"))
            XCTAssertTrue(draft.body.contains(diagnostics.formattedDetails))
            XCTAssertTrue(draft.body.contains("Please describe the issue here."))
        }
    }

    func testMailtoURLUsesPercentEncodingWithoutPlusCharacters() throws {
        let draft = SupportEmailDraft(
            recipient: "dhibi.ywsf@gmail.com",
            subject: "Document Scanner Support - Bug Report",
            body: """
            Hello Document Scanner Support,

            Request Type: Bug Report
            Message:

            OCR export failed after saving a PDF.
            """
        )

        let url = try XCTUnwrap(draft.mailtoURL)
        let absoluteString = url.absoluteString
        XCTAssertFalse(absoluteString.contains("+"))
        XCTAssertTrue(absoluteString.contains("%20"))

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let subject = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "subject" })?.value)
        let body = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "body" })?.value)
        XCTAssertEqual(subject, draft.subject)
        XCTAssertEqual(body, draft.body)
    }

    func testMailtoURLReturnsNilForEmptyRecipient() {
        let draft = SupportEmailDraft(recipient: "", subject: "Subject", body: "Body")
        XCTAssertNil(draft.mailtoURL)
    }

    func testRouterPrefersNativeComposerWhenAvailable() {
        let router = SupportEmailRouter(canSendMail: true)
        let route = router.route(for: SupportEmailDraft(recipient: "dhibi.ywsf@gmail.com", subject: "Subject", body: "Body"))

        XCTAssertEqual(route, .nativeComposer)
    }

    func testRouterFallsBackToExternalURLWhenMailIsUnavailable() throws {
        let router = SupportEmailRouter(canSendMail: false)
        let draft = SupportEmailDraft(recipient: "dhibi.ywsf@gmail.com", subject: "Subject", body: "Body")
        let route = router.route(for: draft)

        guard case let .external(url) = route else {
            return XCTFail("Expected external fallback URL")
        }

        XCTAssertEqual(url, try XCTUnwrap(draft.mailtoURL))
    }

    func testRouterReportsUnavailableWhenFallbackURLCannotBeBuilt() {
        let router = SupportEmailRouter(canSendMail: false)
        let route = router.route(for: SupportEmailDraft(recipient: "", subject: "Subject", body: "Body"))

        XCTAssertEqual(route, .unavailable)
    }

    func testMailComposeCoordinatorPropagatesCompletionResults() {
        var receivedResults: [(MFMailComposeResult, Error?)] = []
        let coordinator = SupportMailComposeCoordinator { result, error in
            receivedResults.append((result, error))
        }
        let controller = MFMailComposeViewController()
        let failure = NSError(domain: "SupportTests", code: 7)

        coordinator.mailComposeController(controller, didFinishWith: .sent, error: nil)
        coordinator.mailComposeController(controller, didFinishWith: .saved, error: nil)
        coordinator.mailComposeController(controller, didFinishWith: .cancelled, error: nil)
        coordinator.mailComposeController(controller, didFinishWith: .failed, error: failure)

        XCTAssertEqual(receivedResults.map(\.0), [.sent, .saved, .cancelled, .failed])
        XCTAssertNil(receivedResults[0].1)
        XCTAssertNil(receivedResults[1].1)
        XCTAssertNil(receivedResults[2].1)
        XCTAssertEqual((receivedResults[3].1 as NSError?)?.domain, "SupportTests")
        XCTAssertEqual((receivedResults[3].1 as NSError?)?.code, 7)
    }

    private func makeDiagnostics() -> SupportDiagnostics {
        SupportDiagnostics(
            appName: "Document Scanner",
            appVersion: "1.0.5",
            buildNumber: "1",
            systemName: "iOS",
            systemVersion: "26.5",
            deviceModel: "iPhone",
            hardwareModel: "iPhone17,1",
            preferredLocale: "en_TN"
        )
    }
}

private struct SupportTopicMetadata: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
}
