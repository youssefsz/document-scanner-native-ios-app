//
//  PDFCoordinateMapper.swift
//  document-scaner
//
//

import CoreGraphics
import Foundation
import Vision

struct PDFCoordinateMapper {
    let imageSize: CGSize
    let pageRect: CGRect

    nonisolated func pageRect(for imageRect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

        let xScale = pageRect.width / imageSize.width
        let yScale = pageRect.height / imageSize.height

        return CGRect(
            x: pageRect.minX + (imageRect.minX * xScale),
            y: pageRect.minY + (imageRect.minY * yScale),
            width: imageRect.width * xScale,
            height: imageRect.height * yScale
        ).integral
    }

    nonisolated static func imageRect(from normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

        return VNImageRectForNormalizedRect(
            normalizedRect,
            Int(imageSize.width.rounded()),
            Int(imageSize.height.rounded())
        )
    }
}
