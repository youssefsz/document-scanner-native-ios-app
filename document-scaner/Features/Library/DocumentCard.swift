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
            RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
