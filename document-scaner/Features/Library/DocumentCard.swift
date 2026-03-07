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
        VStack(alignment: .leading, spacing: 12) {
            DocumentThumbnail(url: document.previewURL)
                .frame(height: 180)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text(document.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44, alignment: .top)

                Text(document.createdAt.formatted(date: .numeric, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct DocumentThumbnail: View {
    let url: URL

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.clear
                    Image(systemName: "doc.text.image")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

#Preview {
    DocumentCard(document: .previewDocument)
        .padding()
}
