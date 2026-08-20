//
//  DocumentExportSheet.swift
//  document-scaner
//
//

import SwiftUI
import UIKit

struct DocumentExportSheet: View {
    @Binding var selectedQuality: DocumentExportQuality
    let originalFileSize: String?
    let preparedExports: [DocumentExportQuality: PreparedDocumentExport]
    let loadingQualities: Set<DocumentExportQuality>
    let isPreparingShare: Bool
    let exportErrorMessage: String?
    @Binding var requiresPassword: Bool
    let passwords: PDFPasswordPair?
    @Binding var isPasswordRevealed: Bool
    let sourceIsSecure: Bool
    let onCancel: () -> Void
    let onSelectionChange: (DocumentExportQuality) -> Void
    let onCopyPassword: () -> Void
    let onGeneratePassword: () -> Bool
    let onShare: () -> Void

    @State private var passwordFeedback: PasswordActionFeedback?
    @State private var passwordFeedbackToken = UUID()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DocumentExportQuality.allCases) { quality in
                        Button {
                            selectedQuality = quality
                        } label: {
                            ExportQualityRow(
                                quality: quality,
                                isSelected: selectedQuality == quality,
                                sizeText: preparedExports[quality]?.formattedFileSize,
                                isLoading: loadingQualities.contains(quality)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparingShare)
                    }
                } header: {
                    Text("Export Quality")
                } footer: {
                    Text("Smaller files are easier to email and upload. The original document saved in your library stays unchanged.")
                }

                Section {
                    ProPasswordToggle(
                        isOn: $requiresPassword,
                        isDisabled: isPreparingShare,
                        onChange: {
                            passwordFeedback = nil
                            isPasswordRevealed = false
                        }
                    )

                    if requiresPassword, let passwords {
                        passwordRow(passwords)
                        copyPasswordButton
                        generatePasswordButton
                    }
                } header: {
                    Text("Security")
                } footer: {
                    if sourceIsSecure && !requiresPassword {
                        Text("This shared copy will not require a password.")
                    } else {
                        Text("Password protection applies only to the shared copy. The library original remains unchanged.")
                    }
                }

                Section {
                    LabeledContent("Saved File Size", value: originalFileSize ?? "Unavailable")
                } header: {
                    Text("Current PDF")
                } footer: {
                    if let exportErrorMessage {
                        Text(exportErrorMessage)
                    }
                }
            }
            .navigationTitle("Share PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isPreparingShare)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onShare) {
                        if isPreparingShare {
                            AppToolbarProgressView(accessibilityLabel: "Preparing PDF")
                        } else {
                            Text("Share")
                        }
                    }
                    .accessibilityLabel(isPreparingShare ? "Preparing PDF" : "Share")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .proPaywallHost()
        .task {
            onSelectionChange(selectedQuality)
        }
        .onChange(of: selectedQuality) { newValue in
            onSelectionChange(newValue)
        }
    }

    private func passwordRow(_ passwords: PDFPasswordPair) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("PDF Password")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    isPasswordRevealed.toggle()
                    passwordFeedback = nil
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(isPasswordRevealed ? "Hide" : "Show")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(isPreparingShare)
                .accessibilityLabel(isPasswordRevealed ? "Hide PDF password" : "Show PDF password")
            }

            Text(isPasswordRevealed ? passwords.displayedUserPassword : "••••-••••-••••-••••")
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .privacySensitive()
                .accessibilityLabel(isPasswordRevealed ? passwords.displayedUserPassword : "Password hidden")

            Text("Use this password exactly as shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var copyPasswordButton: some View {
        Button(action: copyPassword) {
            HStack {
                Text("Copy Password")
                Spacer()
                if passwordFeedback == .copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(isPreparingShare)
        .accessibilityLabel(passwordFeedback == .copied ? "Password copied" : "Copy PDF password for five minutes")
    }

    private var generatePasswordButton: some View {
        Button(action: generatePassword) {
            HStack {
                Text("Generate New Password")
                Spacer()
                if passwordFeedback == .generated {
                    Label("Ready", systemImage: "checkmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(isPreparingShare)
        .accessibilityLabel(passwordFeedback == .generated ? "New password generated" : "Generate a new PDF password")
    }

    private func copyPassword() {
        onCopyPassword()
        showFeedback(.copied)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: "PDF password copied. The clipboard expires in five minutes."
        )
    }

    private func generatePassword() {
        guard onGeneratePassword() else { return }
        showFeedback(.generated)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: "A new PDF password is ready")
    }

    private func showFeedback(_ newFeedback: PasswordActionFeedback) {
        let token = UUID()
        passwordFeedbackToken = token
        withAnimation(.easeInOut(duration: 0.16)) {
            passwordFeedback = newFeedback
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard passwordFeedbackToken == token else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                passwordFeedback = nil
            }
        }
    }
}

private struct ProPasswordToggle: View {
    @Binding var isOn: Bool
    let isDisabled: Bool
    let onChange: () -> Void

    @Environment(\.requestProFeature) private var requestProFeature
    @EnvironmentObject private var proStore: ProStore

    var body: some View {
        Toggle("Require Password", isOn: Binding(
            get: { isOn },
            set: { newValue in
                if !newValue {
                    isOn = false
                    changed()
                } else if proStore.hasAccess(to: .passwordProtectedPDF) {
                    isOn = true
                    changed()
                } else {
                    isOn = false
                    requestProFeature(.passwordProtectedPDF) {
                        isOn = true
                        changed()
                    }
                }
            }
        ))
        .disabled(isDisabled)
    }

    private func changed() {
        onChange()
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

private enum PasswordActionFeedback: Equatable {
    case copied
    case generated
}

private struct ExportQualityRow: View {
    let quality: DocumentExportQuality
    let isSelected: Bool
    let sizeText: String?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(quality.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(quality.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)

                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)

                        Text("Calculating...")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                } else if let sizeText {
                    Text(sizeText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
