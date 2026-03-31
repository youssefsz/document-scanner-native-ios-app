//
//  OCRService.swift
//  document-scaner
//
//

import Foundation
import Vision

enum OCRServiceError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "Text recognition timed out."
        }
    }
}

actor OCRService {
    private let pageTimeout: Duration

    init(pageTimeout: Duration = .seconds(12)) {
        self.pageTimeout = pageTimeout
    }

    func recognizeText(in raster: ScanPageRaster, pageRect: CGRect? = nil) async throws -> [RecognizedTextLine] {
        let configuration = OCRPreferences.currentRequestConfiguration()
        let targetPageRect = pageRect ?? raster.pageRect

        return try await withThrowingTaskGroup(of: [RecognizedTextLine].self) { group in
            group.addTask {
                try Self.performRecognition(in: raster, pageRect: targetPageRect, configuration: configuration)
            }

            group.addTask {
                try await Task.sleep(for: self.pageTimeout)
                throw OCRServiceError.timedOut
            }

            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    private static func performRecognition(
        in raster: ScanPageRaster,
        pageRect: CGRect,
        configuration: OCRRequestConfiguration
    ) throws -> [RecognizedTextLine] {
        try Task.checkCancellation()

        let request = VNRecognizeTextRequest()
        request.revision = configuration.requestRevision
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0
        request.recognitionLanguages = configuration.preferredLanguageCodes

        if #available(iOS 16.0, *), configuration.automaticallyDetectsLanguage {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: raster.cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        let mapper = PDFCoordinateMapper(imageSize: raster.size, pageRect: pageRect)

        let recognizedLines = observations.compactMap { observation -> RecognizedTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }

            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let lineBoundingBox = mapper.pageRect(
                for: PDFCoordinateMapper.imageRect(from: observation.boundingBox, imageSize: raster.size)
            )

            let wordSpans = makeWordSpans(from: candidate, mapper: mapper, imageSize: raster.size)
            return RecognizedTextLine(text: text, boundingBox: lineBoundingBox, words: wordSpans)
        }

        return recognizedLines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 8 {
                return lhs.boundingBox.minY > rhs.boundingBox.minY
            }

            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }

    private static func makeWordSpans(
        from candidate: VNRecognizedText,
        mapper: PDFCoordinateMapper,
        imageSize: CGSize
    ) -> [RecognizedTextSpan] {
        var wordSpans: [RecognizedTextSpan] = []

        candidate.string.enumerateSubstrings(in: candidate.string.startIndex..<candidate.string.endIndex, options: .byWords) { substring, substringRange, _, _ in
            guard let substring else { return }

            do {
                guard let wordObservation = try candidate.boundingBox(for: substringRange) else { return }
                let imageRect = PDFCoordinateMapper.imageRect(from: wordObservation.boundingBox, imageSize: imageSize)
                let pageRect = mapper.pageRect(for: imageRect)
                let text = substring.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else { return }
                wordSpans.append(RecognizedTextSpan(text: text, boundingBox: pageRect, kind: .word))
            } catch {
                return
            }
        }

        return wordSpans.sorted { lhs, rhs in
            lhs.boundingBox.minX < rhs.boundingBox.minX
        }
    }
}
