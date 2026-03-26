//
//  DocumentTitleEditorSheet.swift
//  document-scaner
//
//

import SwiftUI

struct DocumentTitleEditorSheet: View {
    let title: String
    let message: String
    let saveButtonTitle: String
    let cancelButtonTitle: String
    var isSaving = false
    var allowsInteractiveDismiss = true
    @Binding var documentTitle: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var isTitleFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Document Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    TextField("Document name", text: $documentTitle)
                        .font(.body.weight(.medium))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isTitleFieldFocused)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(.systemBackground))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    isTitleFieldFocused
                                    ? Color.accentColor.opacity(0.85)
                                    : Color(uiColor: .separator).opacity(0.3),
                                    lineWidth: isTitleFieldFocused ? 2 : 1
                                )
                        }
                        .shadow(color: Color.black.opacity(0.06), radius: 12, y: 4)
                        .onSubmit(onSave)
                }

                Text("You can change the title again later from the document preview.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button(action: onSave) {
                    Group {
                        if isSaving {
                            ProgressView()
                                .controlSize(.regular)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(saveButtonTitle)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .font(.headline)
                    .padding(.vertical, 16)
                }
                .appProminentButtonStyle()
                .disabled(trimmedTitle.isEmpty || isSaving)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelButtonTitle, action: onCancel)
                        .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving || !allowsInteractiveDismiss)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .task {
            await focusTitleField()
        }
    }

    private var trimmedTitle: String {
        documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func focusTitleField() async {
        guard !isSaving else { return }
        try? await Task.sleep(for: .milliseconds(250))
        isTitleFieldFocused = true
    }
}
