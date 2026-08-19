//
//  DocumentCard.swift
//  document-scaner
//
//

import SwiftUI
import UIKit

enum DocumentCardLayout {
    static let cardCornerRadius: CGFloat = 18
    static let thumbnailCornerRadius: CGFloat = 10
    static let thumbnailHeight: CGFloat = 210
    static let detailsHeight: CGFloat = 46
    static let totalCardHeight: CGFloat = 292
}

struct DocumentCard: View {
    let document: ScannedDocument
    var isSelectionMode = false
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DocumentThumbnail(url: document.previewURL)
                .frame(height: DocumentCardLayout.thumbnailHeight)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 7) {
                Text(document.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")

                        Text(document.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
                    }
                    .lineLimit(1)

                    Text("\u{2022}")
                        .accessibilityHidden(true)

                    HStack(spacing: 3) {
                        Image(systemName: "doc")

                        Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                    }
                    .lineLimit(1)
                }
                .font(.caption2)
                .fontWidth(.condensed)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: DocumentCardLayout.detailsHeight, maxHeight: DocumentCardLayout.detailsHeight, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: DocumentCardLayout.totalCardHeight, maxHeight: DocumentCardLayout.totalCardHeight, alignment: .topLeading)
        .background(
            cardBackground
        )
        .overlay { cardBorder }
        .overlay(alignment: .topTrailing) { selectionBadge }
        .clipShape(RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .scaleEffect(cardScale)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                }
            }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous)
            .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelectionMode {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.85))
                .padding(14)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.9)
        }

        return isSelectionMode ? Color(uiColor: .separator).opacity(0.3) : Color(uiColor: .separator).opacity(0.22)
    }

    private var cardScale: CGFloat {
        guard isSelectionMode else { return 1 }
        return isSelected ? 1 : 0.985
    }

}

struct DocumentThumbnail: View {
    let url: URL

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: ThumbnailPhase = .loading

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(.tertiarySystemFill),
                                Color(.systemFill)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                switch phase {
                case .loaded(let image):
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .transition(reduceMotion ? .identity : .opacity)
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading preview")
                case .unavailable:
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.image")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)

                        Text("No Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: ThumbnailRequest(url: url, size: proxy.size)) {
                phase = .loading
                let image = await ThumbnailPipeline.shared.image(
                    for: url,
                    pointSize: proxy.size,
                    scale: UIScreen.main.scale
                )
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    phase = image.map(ThumbnailPhase.loaded) ?? .unavailable
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        phase = image.map(ThumbnailPhase.loaded) ?? .unavailable
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: DocumentCardLayout.thumbnailCornerRadius, style: .continuous))
    }
}

private enum ThumbnailPhase {
    case loading
    case loaded(UIImage)
    case unavailable
}

private struct ThumbnailRequest: Equatable {
    let url: URL
    let width: Int
    let height: Int

    init(url: URL, size: CGSize) {
        self.url = url
        self.width = Int(size.width.rounded())
        self.height = Int(size.height.rounded())
    }
}

#Preview {
    DocumentCard(document: .previewDocument)
        .padding()
}
