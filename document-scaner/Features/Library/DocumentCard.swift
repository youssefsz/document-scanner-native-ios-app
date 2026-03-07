//
//  DocumentCard.swift
//  document-scaner
//
//  Created by Codex on 7/3/2026.
//

import SwiftUI
import UIKit

struct DocumentCard: View {
    let document: ScannedDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DocumentThumbnail(url: document.previewURL)
                .frame(height: 180)

            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(document.createdAt.formatted(date: .numeric, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct DocumentThumbnail: View {
    let url: URL

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)

            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                Image(systemName: "doc.text.image")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

#Preview {
    DocumentCard(document: .previewDocument)
        .padding()
}
