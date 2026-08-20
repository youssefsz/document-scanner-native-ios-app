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
    @EnvironmentObject private var proStore: ProStore

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
            Section {
                proBanner
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

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

    @ViewBuilder
    private var proBanner: some View {
        switch ProSettingsBannerMode(entitlementState: proStore.entitlementState) {
        case .checking:
            ProSettingsBanner(
                systemImage: nil,
                title: "Checking Pro access...",
                detail: nil,
                showsProgress: true,
                showsChevron: false
            )
        case .owned:
            ProSettingsBanner(
                systemImage: "checkmark.seal.fill",
                title: "DocScanner Pro",
                detail: "Lifetime access unlocked",
                showsProgress: false,
                showsChevron: false
            )
        case .free:
            ProSettingsBannerButton()
        }
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

private struct ProSettingsBanner: View {
    let systemImage: String?
    let title: String
    let detail: String?
    let showsProgress: Bool
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 14) {
            if showsProgress {
                ProgressView()
                    .tint(.white)
                    .accessibilityHidden(true)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.title3)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .opacity(0.88)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(Color.blue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ProSettingsBannerButton: View {
    @Environment(\.requestProFeature) private var requestProFeature

    var body: some View {
        Button {
            requestProFeature(.secureFolder) {}
        } label: {
            ProSettingsBanner(
                systemImage: "lock.shield.fill",
                title: "Unlock DocScanner Pro",
                detail: "Secure folders and protected PDFs",
                showsProgress: false,
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Unlock DocScanner Pro. Secure folders and protected PDFs.")
    }
}

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
        .appGroupedScreenBackground()
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
        "This policy explains what information \(AppMetadata.appName) handles, how the app uses it, and the choices available to you. The app is designed to process and store documents on your device."
    }

    var sections: [LegalDocumentSection] {
        [
            LegalDocumentSection(
                title: "1. Information the app handles",
                paragraphs: [
                    "\(AppMetadata.appName) handles the pages you scan, PDF files, preview images, document and folder titles, creation dates, OCR text, and app settings. The app stores this information locally as part of its normal operation.",
                    "If you use a secure folder, the app also handles encrypted copies of its folder name, documents, previews, and related metadata.",
                    "If you contact support, you choose what to include in your message. A support email may include the app version, build number, iOS version, device and hardware model, preferred language, and any text or attachments you add."
                ]
            ),
            LegalDocumentSection(
                title: "2. How the app uses information",
                paragraphs: [
                    "The app uses the camera only when you choose to scan a document. It turns captured pages into PDF files and preview images so you can view, organize, search, and share them.",
                    "Optical character recognition runs on the device. It adds searchable text to supported PDF files and uses the language preferences you select in Settings.",
                    "Document titles, folder titles, dates, and settings organize your local library and apply your chosen preferences."
                ]
            ),
            LegalDocumentSection(
                title: "3. Local storage and secure folders",
                paragraphs: [
                    "Scanned documents, previews, OCR results, folders, and related metadata are stored in the app's local storage on your device. \(AppMetadata.appName) does not require an account and does not upload your documents to servers controlled by the developer.",
                    "Secure folder names, PDFs, and preview images are encrypted on the device. The encryption key is stored in the iOS Keychain and protected by system authentication.",
                    "When you unlock or create a secure folder, iOS may authenticate you with Face ID, Touch ID, or the device passcode. The app receives only the result of that authentication. It does not receive or store your face, fingerprint, or biometric template.",
                    "The app does not include third-party advertising or analytics SDKs. The developer does not sell or rent your document data or support information."
                ]
            ),
            LegalDocumentSection(
                title: "4. DocScanner Pro purchases",
                paragraphs: [
                    "DocScanner Pro is offered as a one-time, non-consumable in-app purchase. Apple processes the purchase through StoreKit. The developer does not receive or store your payment-card details.",
                    "The app receives limited transaction information needed to display the product, verify or restore access, and respond to a revocation. This can include the product identifier, original transaction identifier, transaction status, and verification date. The app stores a local entitlement record in the iOS Keychain.",
                    "Apple handles purchase information under the Apple Privacy Policy."
                ]
            ),
            LegalDocumentSection(
                title: "5. Permissions",
                paragraphs: [
                    "The app requests camera access so you can scan documents. If you deny camera access, scanning remains unavailable until you allow it in iOS Settings.",
                    "On supported devices, the app requests Face ID access when you choose to create or open a secure folder. iOS manages Face ID, Touch ID, and device-passcode authentication."
                ]
            ),
            LegalDocumentSection(
                title: "6. Sharing, exports, and the clipboard",
                paragraphs: [
                    "The app shares a document only after you choose a destination through the iOS share sheet. The destination you select handles the shared copy under its own privacy policy.",
                    "If you create a password-protected PDF, the app encrypts a temporary export copy. It does not alter the saved source document.",
                    "If you choose to copy a generated PDF password, the app places it on the device-only clipboard with a five-minute expiration. The password may remain available to other apps on your device until it expires or you replace it.",
                    "Information is sent to support only when you choose to send an email. Your email provider and the support mailbox process that message."
                ]
            ),
            LegalDocumentSection(
                title: "7. Retention and deletion",
                paragraphs: [
                    "Your documents remain on your device until you delete them or remove the app. When you delete a document inside the app, the app removes its PDF and preview from local storage. Temporary export copies are removed after the related sharing flow ends.",
                    "Deleting the app or losing access to its encryption key can make secure documents unrecoverable. Save any copies you need before deleting the app or changing devices.",
                    "You may ask for a support message to be deleted by contacting the address below. This does not affect records that Apple controls for App Store purchases."
                ]
            ),
            LegalDocumentSection(
                title: "8. Your choices",
                paragraphs: [
                    "You can delete documents and folders in the app, change OCR preferences in Settings, disable camera or Face ID access in iOS Settings, and decide whether to share a document or contact support.",
                    "Because the app does not operate user accounts or a document server, the developer cannot view, retrieve, or remotely delete documents stored only on your device."
                ]
            ),
            LegalDocumentSection(
                title: "9. Changes to this policy",
                paragraphs: [
                    "This policy may change when the app's features or legal requirements change. The effective date at the top of this page identifies the latest version."
                ]
            ),
            LegalDocumentSection(
                title: "10. Contact",
                paragraphs: [
                    "For privacy questions or deletion requests, contact \(AppMetadata.creatorName) at \(AppMetadata.supportEmail). For product help, visit \(AppMetadata.supportDisplayName)."
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

                    Link(destination: AppMetadata.supportURL) {
                        Label(AppMetadata.supportDisplayName, systemImage: "questionmark.circle")
                    }
                }
                .settingsCardStyle()
            }
            .padding(20)
        }
        .appGroupedScreenBackground()
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
    .environmentObject(ProStore(productIdentifier: nil, startLifecycle: false))
}
