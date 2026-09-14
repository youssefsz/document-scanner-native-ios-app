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
                            HStack(spacing: 14) {
                                Image(systemName: topic.systemImage)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 38, height: 38)
                                    .background(
                                        topic.tintColor,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(topic.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    Text(topic.subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 12)

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Opens a prefilled support email.")
                    }
                } header: {
                    Text("Choose a topic")
                } footer: {
                    Text("We'll prepare an email with your app version and device details. You can review everything before sending.")
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

private extension SupportTopic {
    var tintColor: Color {
        switch self {
        case .bugReport:
            .red
        case .contentIssue:
            .orange
        case .featureSuggestion:
            .yellow
        case .technicalSupport:
            .blue
        case .generalFeedback:
            .purple
        }
    }
}
