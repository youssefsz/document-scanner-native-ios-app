//
//  SettingsView.swift
//  document-scaner
//
//

import MessageUI
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.openURL) private var openURL

    @AppStorage(AppPreferenceKey.documentSortOrder) private var documentSortOrder = DocumentSortOrder.newestFirst.rawValue
    @AppStorage(AppPreferenceKey.defaultExportQuality) private var defaultExportQuality = DocumentExportQuality.high.rawValue
    @AppStorage(AppPreferenceKey.confirmBeforeDelete) private var confirmBeforeDelete = true
    @AppStorage(AppPreferenceKey.useDarkMode) private var useDarkMode = false
    @AppStorage(AppPreferenceKey.ocrAutoDetectLanguage) private var ocrAutoDetectLanguage = true
    @State private var selectedOCRLanguageCodes = OCRPreferences.storedPreferredLanguageCodes()
    @State private var activeAlert: SettingsAlert?
    @State private var isSupportSheetPresented = false
    @State private var activeSupportDraft: SupportEmailDraft?
    @State private var isSupportFlowActive = false
    @State private var pendingSupportTopic: SupportTopic?
#if DEBUG
    @State private var isProPaywallPresented = false
    @State private var proPreviewAlert: ProPreviewAlert?
#endif

    private let supportDiagnosticsProvider: any SupportDiagnosticsProviding
    private let supportDraftBuilder: any SupportEmailDraftBuilding

    init(
        supportDiagnosticsProvider: any SupportDiagnosticsProviding = SystemSupportDiagnosticsProvider(),
        supportDraftBuilder: any SupportEmailDraftBuilding = SupportEmailDraftBuilder()
    ) {
        self.supportDiagnosticsProvider = supportDiagnosticsProvider
        self.supportDraftBuilder = supportDraftBuilder
    }

    var body: some View {
        Form {
#if DEBUG
            Section {
                Button {
                    isProPaywallPresented = true
                } label: {
                    Label("Preview Pro Paywall", systemImage: "crown.fill")
                }
            } header: {
                Text("DocScanner Pro")
            } footer: {
                Text("Visual preview only. StoreKit and Pro ownership are not connected in this build.")
            }
#endif

            Section {
                Toggle("Dark Mode", isOn: $useDarkMode)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Turn this off to keep the app in light mode.")
            }

            Section {
                Picker("Sort Documents", selection: $documentSortOrder) {
                    ForEach(DocumentSortOrder.allCases) { order in
                        Text(order.title).tag(order.rawValue)
                    }
                }

                Picker("PDF Export Quality", selection: $defaultExportQuality) {
                    ForEach(DocumentExportQuality.allCases) { quality in
                        Text(quality.title).tag(quality.rawValue)
                    }
                }

                Toggle("Confirm Before Delete", isOn: $confirmBeforeDelete)
            } header: {
                Text("Library")
            } footer: {
                Text("These settings affect the way documents are displayed, how PDFs are prepared for sharing, and how deletion is handled.")
            }

            Section {
                Toggle("Auto-Detect Languages", isOn: $ocrAutoDetectLanguage)
                    .onChange(of: ocrAutoDetectLanguage) { newValue in
                        OCRPreferences.setStoredAutoDetectLanguage(newValue)
                    }

                NavigationLink {
                    OCRLanguageSelectionView(selectedLanguageCodes: $selectedOCRLanguageCodes)
                } label: {
                    LabeledContent("Preferred Languages", value: ocrLanguageSummary)
                }
            } header: {
                Text("Text Recognition")
            } footer: {
                Text("Searchable PDFs are created fully offline using on-device OCR. Preferred languages are used as recognition hints, and auto-detect expands recognition when the request supports it.")
            }

            Section {
                Button {
                    openAppSettings()
                } label: {
                    Label("Open iOS Settings", systemImage: "gear.badge")
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Use this if you want to review camera permission for scanning.")
            }

            Section {
                NavigationLink("About This App") {
                    AboutAppView()
                }

                if let appStoreReviewURL = AppMetadata.appStoreReviewURL {
                    Link(destination: appStoreReviewURL) {
                        Label("Rate on the App Store", systemImage: "star.bubble")
                    }
                } else {
                    Label("Rate on the App Store", systemImage: "star.bubble")
                        .foregroundStyle(.secondary)
                }

                Button {
                    presentSupportTopics()
                } label: {
                    Label("Email Support", systemImage: "envelope")
                }
                .disabled(isSupportFlowActive)

                Button {
                    UIPasteboard.general.string = supportDiagnosticsProvider.currentDiagnostics().formattedDetails
                    activeAlert = .copied
                } label: {
                    Label("Copy App Details", systemImage: "doc.on.doc")
                }

                NavigationLink("Privacy Policy") {
                    LegalDocumentView(document: .privacy)
                }

                Link(destination: AppMetadata.standardEULAURL) {
                    Label("Terms of Use", systemImage: "doc.text")
                }
            } header: {
                Text("About & Legal")
            } footer: {
                if AppMetadata.appStoreReviewURL == nil {
                    Text("Add the app's numeric App Store ID to the `AppStoreID` Info.plist value to enable the review page button. Support opens your email app with your app version and device details included.")
                } else {
                    Text("Support opens your email app with your app version and device details included.")
                }
            }

            Section {
                VStack(spacing: 10) {
                    Image("LaunchIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text(AppMetadata.versionDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedOCRLanguageCodes = OCRPreferences.storedPreferredLanguageCodes()
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .copied:
                Alert(
                    title: Text("Copied"),
                    message: Text("App details were copied to the clipboard."),
                    dismissButton: .cancel(Text("OK"))
                )

            case .supportUnavailable:
                Alert(
                    title: Text("Unable to Open Email"),
                    message: Text("No email app is available. You can copy the app details and contact \(AppMetadata.supportEmail) manually."),
                    dismissButton: .cancel(Text("OK"))
                )
            }
        }
#if DEBUG
        .sheet(isPresented: $isProPaywallPresented) {
            ProPaywallView(
                configuration: .preview,
                onPurchase: {
                    proPreviewAlert = .purchase
                },
                onRestore: {
                    proPreviewAlert = .restore
                },
                onDismiss: {
                    isProPaywallPresented = false
                }
            )
            .alert(item: $proPreviewAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .cancel(Text("OK"))
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
#endif
        .sheet(isPresented: $isSupportSheetPresented, onDismiss: handleSupportTopicSheetDismissal) {
            SupportFeedbackSheet { topic in
                pendingSupportTopic = topic
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $activeSupportDraft, onDismiss: finishSupportFlow) { draft in
            SupportMailComposeView(draft: draft) { result, error in
                activeSupportDraft = nil
                isSupportFlowActive = false

                if result == .failed || error != nil {
                    activeAlert = .supportUnavailable
                }
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func presentSupportTopics() {
        guard !isSupportFlowActive else { return }

        isSupportFlowActive = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        isSupportSheetPresented = true
    }

    private func prepareSupportEmail(for topic: SupportTopic) {
        guard isSupportFlowActive else { return }

        UISelectionFeedbackGenerator().selectionChanged()

        let diagnostics = supportDiagnosticsProvider.currentDiagnostics()
        let draft = supportDraftBuilder.makeDraft(topic: topic, diagnostics: diagnostics)

        Task { @MainActor in
            let emailRouter = SupportEmailRouter(
                canSendMail: MFMailComposeViewController.canSendMail()
            )

            switch emailRouter.route(for: draft) {
            case .nativeComposer:
                activeSupportDraft = draft

            case let .external(url):
                openURL(url) { accepted in
                    Task { @MainActor in
                        isSupportFlowActive = false
                        if !accepted {
                            activeAlert = .supportUnavailable
                        }
                    }
                }

            case .unavailable:
                isSupportFlowActive = false
                activeAlert = .supportUnavailable
            }
        }
    }

    private func handleSupportTopicSheetDismissal() {
        if let pendingSupportTopic {
            self.pendingSupportTopic = nil
            prepareSupportEmail(for: pendingSupportTopic)
            return
        }

        if activeSupportDraft == nil {
            isSupportFlowActive = false
        }
    }

    private func finishSupportFlow() {
        activeSupportDraft = nil
        isSupportFlowActive = false
    }

    private var ocrLanguageSummary: String {
        let optionsByCode = Dictionary(uniqueKeysWithValues: OCRPreferences.availableLanguageOptions().map { ($0.code, $0.displayName) })
        let titles = selectedOCRLanguageCodes.compactMap { optionsByCode[$0] }

        if titles.isEmpty {
            return "Device Defaults"
        }

        return titles.joined(separator: ", ")
    }
}

private enum SettingsAlert: String, Identifiable {
    case copied
    case supportUnavailable

    var id: String { rawValue }
}

#if DEBUG
private enum ProPreviewAlert: String, Identifiable {
    case purchase
    case restore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .purchase:
            "Purchase Preview"
        case .restore:
            "Restore Preview"
        }
    }

    var message: String {
        switch self {
        case .purchase:
            "StoreKit is not connected. This preview does not charge you or unlock DocScanner Pro."
        case .restore:
            "StoreKit is not connected. This preview does not restore or create a Pro entitlement."
        }
    }
}
#endif

private struct OCRLanguageSelectionView: View {
    @Binding var selectedLanguageCodes: [String]
    @State private var availableLanguages = OCRPreferences.availableLanguageOptions()

    var body: some View {
        List {
            ForEach(availableLanguages) { option in
                Button {
                    toggleSelection(for: option.code)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.displayName)
                                .foregroundStyle(.primary)

                            Text(option.code)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: selectedLanguageCodes.contains(option.code) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedLanguageCodes.contains(option.code) ? Color.accentColor : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("OCR Languages")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            availableLanguages = OCRPreferences.availableLanguageOptions()
            selectedLanguageCodes = OCRPreferences.storedPreferredLanguageCodes()
        }
    }

    private func toggleSelection(for code: String) {
        if let index = selectedLanguageCodes.firstIndex(of: code) {
            selectedLanguageCodes.remove(at: index)
        } else {
            selectedLanguageCodes.append(code)
        }

        selectedLanguageCodes = OCRPreferences.intersectWithSupportedLanguages(selectedLanguageCodes)
        OCRPreferences.setStoredPreferredLanguageCodes(selectedLanguageCodes)
    }
}

private struct AboutAppView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppMetadata.appName)
                        .font(.largeTitle.weight(.bold))

                    Text("Scan paper documents into PDF files, keep them organized locally on your device, and choose the export quality when you share them.")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Text(AppMetadata.versionDescription)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .settingsCardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    Text("What It Does")
                        .font(.headline)

                    FeatureRow(icon: "document.viewfinder", title: "Document scanning", detail: "Capture one or more pages using Apple's native scanning interface.")
                    FeatureRow(icon: "doc.richtext", title: "PDF generation", detail: "Each scan is converted into a PDF file and saved inside the app's local storage.")
                    FeatureRow(icon: "externaldrive", title: "Local-first storage", detail: "Documents, preview images, and metadata stay on your device unless you share them.")
                    FeatureRow(icon: "square.and.arrow.up", title: "Smart sharing", detail: "Choose Low, Medium, High, or Very High export quality and review the shared file size before sending a document.")
                }
                .settingsCardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Privacy At A Glance")
                        .font(.headline)

                    Text("The app does not require an account, does not include third-party analytics or advertising SDKs, and does not upload your scans to developer-controlled servers.")
                        .foregroundStyle(.secondary)

                    Text("Camera access is requested only so you can scan documents. If you remove a document, the app deletes the associated PDF and preview image from local storage.")
                        .foregroundStyle(.secondary)
                }
                .settingsCardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Creator")
                        .font(.headline)

                    HStack {
                        Text("Developed by")
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(AppMetadata.creatorName)
                            .multilineTextAlignment(.trailing)
                    }

                    Link(destination: AppMetadata.portfolioURL) {
                        Label(AppMetadata.portfolioDisplayName, systemImage: "globe")
                    }
                    .font(.body.weight(.medium))
                }
                .settingsCardStyle()
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LegalDocumentSection: Identifiable {
    let id = UUID()
    let title: String
    let paragraphs: [String]
}

private enum LegalDocumentKind {
    case privacy

    var title: String {
        "Privacy Policy"
    }

    var summary: String {
        "This policy explains what information \(AppMetadata.appName) handles, how that information is used, and the choices you have."
    }

    var sections: [LegalDocumentSection] {
        [
            LegalDocumentSection(
                title: "1. Information The App Handles",
                paragraphs: [
                    "\(AppMetadata.appName) lets you scan paper documents, create PDF files, save document titles, and generate preview images. This information is stored locally on your device as part of the app's normal operation.",
                    "If you contact support by email, you may also choose to send diagnostic details such as the app version, your iOS version, and any information you include in your message."
                ]
            ),
            LegalDocumentSection(
                title: "2. How Information Is Used",
                paragraphs: [
                    "The app uses the camera only when you choose to scan a document. Captured pages are used to create PDFs and preview images so you can view, organize, and share your files inside the app.",
                    "Document titles and creation dates are used only to organize your library on-device."
                ]
            ),
            LegalDocumentSection(
                title: "3. Storage And Sharing",
                paragraphs: [
                    "Scanned documents, preview images, and related metadata are stored locally on your device in the app's application support directory.",
                    "The app does not require user accounts, does not include third-party advertising or analytics SDKs, and does not upload your documents to developer-controlled servers.",
                    "Documents are shared only when you explicitly choose a destination using the iOS share sheet or when you include information in a support email that you send voluntarily."
                ]
            ),
            LegalDocumentSection(
                title: "4. Permissions",
                paragraphs: [
                    "The app requests camera access so it can scan documents. If camera access is denied, scanning will not be available until permission is granted in iOS Settings."
                ]
            ),
            LegalDocumentSection(
                title: "5. Retention And Deletion",
                paragraphs: [
                    "Your documents remain on your device until you delete them or remove the app. When you delete a document inside the app, the associated PDF file and preview image are removed from local storage."
                ]
            ),
            LegalDocumentSection(
                title: "6. Contact",
                paragraphs: [
                    "If you have questions about this Privacy Policy, contact \(AppMetadata.creatorName) at \(AppMetadata.supportEmail) or visit \(AppMetadata.portfolioDisplayName)."
                ]
            )
        ]
    }
}

private struct LegalDocumentView: View {
    let document: LegalDocumentKind

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(document.title)
                        .font(.title2.weight(.bold))

                    Text(document.summary)
                        .foregroundStyle(.secondary)

                    Text("Effective date: \(AppMetadata.legalEffectiveDate)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .settingsCardStyle()

                ForEach(document.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.headline)

                        ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .settingsCardStyle()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Contact")
                        .font(.headline)

                    if let supportEmailURL = AppMetadata.supportEmailURL {
                        Link(destination: supportEmailURL) {
                            Label(AppMetadata.supportEmail, systemImage: "envelope")
                        }
                    } else {
                        Label(AppMetadata.supportEmail, systemImage: "envelope")
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: AppMetadata.portfolioURL) {
                        Label(AppMetadata.portfolioDisplayName, systemImage: "globe")
                    }
                }
                .settingsCardStyle()
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        LegalDocumentView(document: .privacy)
    }
}

private extension View {
    func settingsCardStyle() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
