//
//  DocumentTitleEditorSheet.swift
//  document-scaner
//
//  Created by Codex on 8/3/2026.
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
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.title3.weight(.semibold))

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                TextField("Document name", text: $documentTitle)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($isTitleFieldFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator).opacity(0.18), lineWidth: 1)
                    }
                    .onSubmit(onSave)

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
                .buttonStyle(.glassProminent)
                .disabled(trimmedTitle.isEmpty || isSaving)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.systemGroupedBackground))
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
        .onAppear {
            isTitleFieldFocused = true
        }
    }

    private var trimmedTitle: String {
        documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
