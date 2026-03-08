//
//  DocumentCard.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import SwiftUI
import UIKit

enum DocumentCardLayout {
    static let cardCornerRadius: CGFloat = 28
    static let thumbnailHeight: CGFloat = 176
    static let detailsHeight: CGFloat = 92
    static let totalCardHeight: CGFloat = 304
}

struct DocumentCard: View {
    let document: ScannedDocument
    var isSelectionMode = false
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DocumentThumbnail(url: document.previewURL)
                .frame(height: DocumentCardLayout.thumbnailHeight)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text(document.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 44, alignment: .top)
                    .clipped()

                Text(document.createdAt.formatted(date: .numeric, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: DocumentCardLayout.detailsHeight, maxHeight: DocumentCardLayout.detailsHeight, alignment: .topLeading)
            .padding(.horizontal, 2)
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
        .shadow(color: shadowColor, radius: shadowRadius, y: shadowYOffset)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: backgroundColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
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

    private var backgroundColors: [Color] {
        if isSelected {
            [
                Color.accentColor.opacity(0.18),
                Color(.secondarySystemGroupedBackground)
            ]
        } else if isSelectionMode {
            [
                Color(.secondarySystemGroupedBackground),
                Color(.tertiarySystemGroupedBackground)
            ]
        } else {
            [
                Color(.secondarySystemGroupedBackground),
                Color(.secondarySystemGroupedBackground)
            ]
        }
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.9)
        }

        return isSelectionMode ? Color(uiColor: .quaternaryLabel).opacity(0.3) : Color(uiColor: .quaternaryLabel).opacity(0.22)
    }

    private var cardScale: CGFloat {
        guard isSelectionMode else { return 1 }
        return isSelected ? 1 : 0.985
    }

    private var shadowColor: Color {
        isSelected ? Color.accentColor.opacity(0.14) : Color.black.opacity(isSelectionMode ? 0.06 : 0.08)
    }

    private var shadowRadius: CGFloat {
        isSelected ? 18 : 12
    }

    private var shadowYOffset: CGFloat {
        isSelected ? 10 : 6
    }
}

private struct DocumentThumbnail: View {
    let url: URL

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

                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#Preview {
    DocumentCard(document: .previewDocument)
        .padding()
}
