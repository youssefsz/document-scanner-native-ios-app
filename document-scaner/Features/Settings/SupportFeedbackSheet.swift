//
//  SupportFeedbackSheet.swift
//  document-scaner
//

import SwiftUI

struct SupportFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSelectTopic: (SupportTopic) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SupportTopic.allCases) { topic in
                        Button {
                            dismiss()
                            onSelectTopic(topic)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: topic.systemImage)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(topic.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)

                                    Text(topic.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 12)

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Opens a prefilled support email.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Support & Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
