//
//  SettingsView.swift
//  document-scaner
//
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.documentSortOrder) private var documentSortOrder = DocumentSortOrder.newestFirst.rawValue
    @AppStorage(AppPreferenceKey.defaultExportQuality) private var defaultExportQuality = DocumentExportQuality.high.rawValue
    @AppStorage(AppPreferenceKey.confirmBeforeDelete) private var confirmBeforeDelete = true
    @AppStorage(AppPreferenceKey.useDarkMode) private var useDarkMode = false
    @AppStorage(AppPreferenceKey.ocrAutoDetectLanguage) private var ocrAutoDetectLanguage = true
    @State private var selectedOCRLanguageCodes = OCRPreferences.storedPreferredLanguageCodes()
    @State private var didCopyAppDetails = false

    var body: some View {
        Form {
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

                Link(destination: AppMetadata.supportEmailURL) {
                    Label("Email Support", systemImage: "envelope")
                }

                Button {
                    UIPasteboard.general.string = AppMetadata.supportDetails
                    didCopyAppDetails = true
                } label: {
                    Label("Copy App Details", systemImage: "doc.on.doc")
                }

                NavigationLink("Privacy Policy") {
                    LegalDocumentView(document: .privacy)
                }

                NavigationLink("Terms of Use") {
                    LegalDocumentView(document: .terms)
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
        .alert("Copied", isPresented: $didCopyAppDetails) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("App details were copied to the clipboard.")
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
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
    case terms

    var title: String {
        switch self {
        case .privacy:
            "Privacy Policy"
        case .terms:
            "Terms of Use"
        }
    }

    var summary: String {
        switch self {
        case .privacy:
            "This policy explains what information \(AppMetadata.appName) handles, how that information is used, and the choices you have."
        case .terms:
            "These terms govern your use of \(AppMetadata.appName) and explain the responsibilities that apply when you use the app."
        }
    }

    var sections: [LegalDocumentSection] {
        switch self {
        case .privacy:
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
        case .terms:
            [
                LegalDocumentSection(
                    title: "1. Acceptance Of Terms",
                    paragraphs: [
                        "By downloading or using \(AppMetadata.appName), you agree to these Terms of Use. If you do not agree, do not use the app."
                    ]
                ),
                LegalDocumentSection(
                    title: "2. Permitted Use",
                    paragraphs: [
                        "\(AppMetadata.appName) is provided for scanning, organizing, viewing, and sharing documents on your own device. You may use the app only in compliance with applicable laws and regulations."
                    ]
                ),
                LegalDocumentSection(
                    title: "3. Your Responsibilities",
                    paragraphs: [
                        "You are responsible for the documents and information you scan, store, export, or share through the app.",
                        "You should review scanned documents before relying on them in legal, financial, medical, or other important contexts where accuracy matters."
                    ]
                ),
                LegalDocumentSection(
                    title: "4. Availability And Changes",
                    paragraphs: [
                        "The app may be updated, improved, modified, or discontinued at any time. Features may change as the product evolves."
                    ]
                ),
                LegalDocumentSection(
                    title: "5. Disclaimer",
                    paragraphs: [
                        "To the fullest extent permitted by law, the app is provided on an \"as is\" and \"as available\" basis without warranties of any kind, whether express or implied."
                    ]
                ),
                LegalDocumentSection(
                    title: "6. Limitation Of Liability",
                    paragraphs: [
                        "To the fullest extent permitted by law, \(AppMetadata.creatorName) will not be liable for indirect, incidental, special, consequential, or punitive damages, or for loss of data, arising from your use of the app."
                    ]
                ),
                LegalDocumentSection(
                    title: "7. Contact",
                    paragraphs: [
                        "Questions about these Terms of Use can be sent to \(AppMetadata.supportEmail)."
                    ]
                )
            ]
        }
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

                    Link(destination: AppMetadata.supportEmailURL) {
                        Label(AppMetadata.supportEmail, systemImage: "envelope")
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
