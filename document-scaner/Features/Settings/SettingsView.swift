//
//  SettingsView.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage(AppPreferenceKey.documentSortOrder) private var documentSortOrder = DocumentSortOrder.newestFirst.rawValue
    @AppStorage(AppPreferenceKey.confirmBeforeDelete) private var confirmBeforeDelete = true
    @AppStorage(AppPreferenceKey.useDarkMode) private var useDarkMode = false
    @State private var stagedUseDarkMode = false
    @State private var themeUpdateTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle("Dark Mode", isOn: darkModeBinding)
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

                Toggle("Confirm Before Delete", isOn: $confirmBeforeDelete)
            } header: {
                Text("Library")
            } footer: {
                Text("These settings affect the document list and delete flow in the current MVP.")
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

                NavigationLink("Support") {
                    SupportView()
                }

                NavigationLink("Privacy Policy") {
                    LegalDocumentView(document: .privacy)
                }

                NavigationLink("Terms of Use") {
                    LegalDocumentView(document: .terms)
                }
            } header: {
                Text("About & Legal")
            }

            Section {
                Text(AppMetadata.versionDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            stagedUseDarkMode = useDarkMode
        }
        .onChange(of: useDarkMode) { _, newValue in
            guard stagedUseDarkMode != newValue else { return }
            stagedUseDarkMode = newValue
        }
        .onDisappear {
            themeUpdateTask?.cancel()
        }
    }

    private var darkModeBinding: Binding<Bool> {
        Binding(
            get: { stagedUseDarkMode },
            set: { newValue in
                stagedUseDarkMode = newValue
                queueThemeUpdate(newValue)
            }
        )
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func queueThemeUpdate(_ newValue: Bool) {
        themeUpdateTask?.cancel()
        themeUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(180))

            guard !Task.isCancelled else { return }
            useDarkMode = newValue
        }
    }
}

private struct AboutAppView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("About This App")
                        .font(.title3.weight(.semibold))

                    Text("This MVP focuses on one job: scan paper documents, turn them into PDFs, and keep them locally on your device with a clean Apple-native interface.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("What It Does") {
                Label("Scans documents with VisionKit", systemImage: "document.viewfinder")
                Label("Stores PDFs and previews locally", systemImage: "externaldrive")
                Label("Lets you preview, share, and delete scans", systemImage: "square.and.arrow.up")
            }

            Section("Current MVP Scope") {
                Text("No account system, no cloud sync, and no OCR workflow yet. The goal is a reliable local-first scanner.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(AppMetadata.versionDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SupportView: View {
    @State private var didCopyAppDetails = false

    var body: some View {
        List {
            Section("Need Help?") {
                Text("For this MVP, the most useful support actions are checking camera permission, confirming you are on a physical device for scanning, and sharing app details when reporting a bug.")
                    .foregroundStyle(.secondary)
            }

            Section("Actions") {
                Button {
                    openAppSettings()
                } label: {
                    Label("Open iOS Settings", systemImage: "gear.badge")
                }

                ShareLink(item: AppMetadata.supportDetails) {
                    Label("Share App Details", systemImage: "square.and.arrow.up")
                }

                Button {
                    UIPasteboard.general.string = AppMetadata.supportDetails
                    didCopyAppDetails = true
                } label: {
                    Label("Copy App Details", systemImage: "doc.on.doc")
                }
            }

            Section("Troubleshooting") {
                Text("Scanning requires camera access and a physical iPhone or iPad. The simulator can build and preview the app, but it cannot perform real document capture.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
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

    var bodyText: String {
        switch self {
        case .privacy:
            """
            This app stores scanned documents locally on your device.

            The camera is used only when you choose to scan a document.

            In this MVP, the app does not create accounts, upload your scans to a server, or require cloud storage to function.

            Shared documents are only sent where you explicitly choose to share them using the system share sheet.

            If you delete a document, the app removes the saved PDF and preview image from local storage.
            """
        case .terms:
            """
            This MVP is provided for scanning and managing personal documents on-device.

            You are responsible for the content you scan, store, and share from the app.

            The app is provided as-is in its current MVP state. Features and behavior may change as the product evolves.

            You should review scanned documents before sharing or relying on them in any important workflow.
            """
        }
    }
}

private struct LegalDocumentView: View {
    let document: LegalDocumentKind

    var body: some View {
        ScrollView {
            Text(document.bodyText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
