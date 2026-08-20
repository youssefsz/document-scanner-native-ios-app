//
//  LibraryComponents.swift
//  document-scaner
//
//

import SwiftUI
import UIKit

struct LibraryToolbarTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .appToolbarTitleSurface()
            .accessibilityAddTraits(.isHeader)
    }
}

enum LibraryScrollCoordinateSpace {
    static let name = "library-scroll"
}

struct LibraryScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct LibraryScrollPositionReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: LibraryScrollOffsetPreferenceKey.self,
                    value: proxy.frame(in: .named(LibraryScrollCoordinateSpace.name)).minY
                )
        }
        .frame(height: 0)
        .accessibilityHidden(true)
    }
}

struct LibraryDocumentTile: View {
    let document: ScannedDocument
    let cardWidth: CGFloat?
    let isSelectionMode: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        DocumentCard(
            document: document,
            isSelectionMode: isSelectionMode,
            isSelected: isSelected
        )
        .frame(width: cardWidth, height: DocumentCardLayout.totalCardHeight)
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(document.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(isSelectionMode ? "Double tap to toggle selection." : "Double tap to open. Long press to start selecting.")
        .accessibilityAddTraits(.isButton)
    }
}

struct LibrarySelectionBar: View {
    let selectionCount: Int
    let isDeleting: Bool
    let isMoving: Bool
    let moveAction: () -> Void
    let deleteAction: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectionCount == 1 ? "1 document selected" : "\(selectionCount) documents selected")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("Choose an action for the current selection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    moveButton
                    deleteButton
                }
            } else {
                HStack(spacing: 12) {
                    moveButton
                    deleteButton
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
    }

    private var moveButton: some View {
        Button(action: moveAction) {
            Label("Move", systemImage: "folder")
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
        .disabled(selectionCount == 0 || isDeleting || isMoving)
    }

    private var deleteButton: some View {
        Button {
            guard !isDeleting else { return }
            deleteAction()
        } label: {
            Group {
                if isDeleting {
                    AppProminentProgressView(accessibilityLabel: "Deleting documents")
                        .controlSize(.regular)
                        .frame(height: 22)
                } else {
                    Label("Delete", systemImage: "trash")
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .appProminentButtonStyle(color: .red)
        .disabled(selectionCount == 0 || isMoving)
        .accessibilityLabel(isDeleting ? "Deleting documents" : "Delete")
    }
}

struct FolderCard: View {
    let summary: FolderSummary
    var isAuthenticating = false

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summary.folder.isSecure {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                    if isAuthenticating {
                        ProgressView()
                            .controlSize(.regular)
                            .accessibilityLabel("Authenticating")
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 142)
            } else if summary.newestDocuments.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                    Image(systemName: "folder")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 142)
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(0..<4, id: \.self) { index in
                        if summary.newestDocuments.indices.contains(index) {
                            DocumentThumbnail(url: summary.newestDocuments[index].previewURL)
                                .frame(height: 68)
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                                .frame(height: 68)
                        }
                    }
                }
                .frame(height: 142)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(summary.folder.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if summary.folder.isSecure {
                        Image(systemName: "lock.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                Text("\(summary.documentCount) document\(summary.documentCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.folder.name), \(summary.documentCount) documents\(summary.folder.isSecure ? ", Secure" : "")")
        .accessibilityHint("Opens folder")
    }
}


struct SearchAwareScanAccessory<Content: View>: View {
    @Environment(\.isSearching) private var isSearching
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group {
            if !isSearching {
                content
            }
        }
        .animation(searchAnimation, value: isSearching)
    }

    private var searchAnimation: Animation? {
        accessibilityReduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)
    }
}

extension View {
    @ViewBuilder
    func librarySearchable(enabled: Bool, text: Binding<String>, prompt: String) -> some View {
        if enabled {
            searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }
}

enum Haptics {
    static func selectionChanged() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
}
