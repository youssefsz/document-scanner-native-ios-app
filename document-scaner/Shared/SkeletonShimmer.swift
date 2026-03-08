//
//  SkeletonShimmer.swift
//  document-scaner
//
//  Created by Codex on 8/3/2026.
//

import SwiftUI

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(.secondarySystemFill),
                        Color(.tertiarySystemFill)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: width, height: height)
            .modifier(ShimmerModifier())
    }
}

private struct ShimmerModifier: ViewModifier {
    @State private var shimmerOffset: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width

                    LinearGradient(
                        colors: [
                            .clear,
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.45),
                            Color.white.opacity(0.12),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: width * 0.85)
                    .offset(x: shimmerOffset * width * 1.8)
                    .blendMode(.plusLighter)
                }
                .clipped()
            }
            .onAppear {
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                    shimmerOffset = 1.2
                }
            }
    }
}

struct DocumentCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))

                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.systemFill))
                        .frame(width: 92, height: 122)
                        .rotationEffect(.degrees(-7))
                        .offset(x: -18, y: 4)
                        .modifier(ShimmerModifier())

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 92, height: 122)
                        .rotationEffect(.degrees(5))
                        .offset(x: 18, y: -2)
                        .modifier(ShimmerModifier())

                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(width: 58, height: 10, cornerRadius: 5)
                        SkeletonBlock(width: 72, height: 10, cornerRadius: 5)
                        SkeletonBlock(width: 50, height: 10, cornerRadius: 5)
                    }
                    .frame(width: 84, height: 108, alignment: .topLeading)
                    .padding(.top, 18)
                    .offset(y: -2)
                }
            }
            .frame(height: 180)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(height: 16, cornerRadius: 8)
                SkeletonBlock(width: 112, height: 16, cornerRadius: 8)
                SkeletonBlock(width: 94, height: 12, cornerRadius: 6)
                SkeletonBlock(width: 62, height: 10, cornerRadius: 5)
            }
            .padding(.horizontal, 2)
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            minHeight: DocumentCardLayout.totalCardHeight,
            maxHeight: DocumentCardLayout.totalCardHeight,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: DocumentCardLayout.cardCornerRadius, style: .continuous))
    }
}

struct LibraryLoadingSkeletonView: View {
    let cardWidth: CGFloat
    let spacing: CGFloat

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: spacing) {
                    DocumentCardSkeleton()
                        .frame(width: cardWidth, height: DocumentCardLayout.totalCardHeight)

                    DocumentCardSkeleton()
                        .frame(width: cardWidth, height: DocumentCardLayout.totalCardHeight)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 140)
    }
}

struct DocumentPreviewSkeleton: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.systemFill))
                    .frame(width: 208, height: 270)
                    .rotationEffect(.degrees(-5))
                    .offset(x: -20, y: 10)
                    .modifier(ShimmerModifier())

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 208, height: 270)
                    .rotationEffect(.degrees(4))
                    .offset(x: 18, y: -6)
                    .modifier(ShimmerModifier())

                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBlock(width: 78, height: 12, cornerRadius: 6)
                    SkeletonBlock(height: 14, cornerRadius: 7)
                    SkeletonBlock(width: 116, height: 14, cornerRadius: 7)
                    SkeletonBlock(height: 14, cornerRadius: 7)
                    SkeletonBlock(width: 94, height: 14, cornerRadius: 7)
                }
                .frame(width: 156, height: 208, alignment: .topLeading)
                .padding(.top, 34)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}
