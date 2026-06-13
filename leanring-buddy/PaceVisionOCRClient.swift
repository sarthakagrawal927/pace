//
//  PaceVisionOCRClient.swift
//  leanring-buddy
//
//  Thin async wrapper around Apple's Vision-framework text recogniser
//  (`VNRecognizeTextRequest`). Native, on-device, ~50-200 ms per
//  screenshot. The VLM tells us "what kind of element this is and
//  where"; Vision tells us "the exact text inside it." Running both
//  in parallel and merging by bbox overlap gives us better text
//  fidelity than either VLM model could on its own.
//

import CoreGraphics
import Foundation
import Vision

/// One block of text Vision detected, with its position in screenshot
/// pixel coordinates (top-left origin, x-right / y-down — matches the
/// coordinate space the VLM uses, so the merge step doesn't need to
/// flip axes).
nonisolated struct RecognizedTextBox: Hashable {
    let text: String
    /// `[x, y, width, height]` in screenshot pixels.
    let pixelBoundingBox: [Int]
}

final class PaceVisionOCRClient {
    /// `accurate` runs the Vision OCR's heavier neural model — slower
    /// (~150-250 ms on a busy screenshot) but markedly better at small
    /// text and code. `fast` (~30-70 ms) misses small text and is too
    /// lossy for our use case. For voice-Q&A latency, accurate fits
    /// inside the user's natural speech window so we use it.
    private let recognitionLevel: VNRequestTextRecognitionLevel = .accurate

    /// Recognise text in a screenshot. JPEG (or PNG) bytes go in,
    /// the list of detected text + bboxes comes out. Throws on hard
    /// decoder errors; an empty result on a blank screen is normal.
    func recognizeText(
        in screenshotImageData: Data,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) async throws -> [RecognizedTextBox] {
        try await withCheckedThrowingContinuation { continuation in
            // Off the main actor — Vision's request handler does its
            // own thread management.
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let recognizedBoxes: [RecognizedTextBox] = observations.compactMap { observation in
                    guard let topCandidate = observation.topCandidates(1).first else {
                        return nil
                    }
                    let trimmedText = topCandidate.string
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedText.isEmpty else { return nil }

                    // Vision normalised bbox: (0,0) is BOTTOM-left, y
                    // grows up, all values in [0, 1]. Convert to
                    // screenshot pixel coords with top-left origin so
                    // it matches the VLM's coordinate space.
                    let normalisedRect = observation.boundingBox
                    let pixelX = Int(normalisedRect.origin.x * CGFloat(screenshotWidthInPixels))
                    let pixelW = Int(normalisedRect.size.width * CGFloat(screenshotWidthInPixels))
                    let pixelH = Int(normalisedRect.size.height * CGFloat(screenshotHeightInPixels))
                    // Flip Y: top-left = imageHeight - (normalisedY + normalisedHeight) * imageHeight
                    let pixelY = Int(
                        (1.0 - normalisedRect.origin.y - normalisedRect.size.height)
                            * CGFloat(screenshotHeightInPixels)
                    )

                    return RecognizedTextBox(
                        text: trimmedText,
                        pixelBoundingBox: [pixelX, pixelY, pixelW, pixelH]
                    )
                }

                continuation.resume(returning: recognizedBoxes)
            }
            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = true

            let imageRequestHandler = VNImageRequestHandler(
                data: screenshotImageData,
                options: [:]
            )
            do {
                try imageRequestHandler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Merge with VLM

enum PaceScreenContextMerger {
    /// Enrich a VLM screen analysis with verbatim OCR text. For each
    /// VLM element with a valid bbox, we look up the OCR boxes that
    /// fall inside it (or overlap > 50%) and replace the element's
    /// `text` field with the concatenated OCR text. Falls back to the
    /// VLM's own text when no OCR box overlaps (e.g. icons, images).
    // Pure value-type transform with no actor-bound state, so it stays
    // nonisolated and can be called from background task groups and tests.
    nonisolated static func enrich(
        vlmAnalysis: LocalVLMScreenAnalysis,
        with ocrBoxes: [RecognizedTextBox]
    ) -> LocalVLMScreenAnalysis {
        guard !ocrBoxes.isEmpty else { return vlmAnalysis }

        let enrichedElements = vlmAnalysis.elements.map { vlmElement -> LocalVLMScreenElement in
            guard vlmElement.bbox.count == 4 else { return vlmElement }

            let elementRect = CGRect(
                x: vlmElement.bbox[0],
                y: vlmElement.bbox[1],
                width: vlmElement.bbox[2],
                height: vlmElement.bbox[3]
            )
            // Skip degenerate rects (width or height ≤ 0). Without this
            // the contains/intersects checks below behave unpredictably.
            guard elementRect.width > 0, elementRect.height > 0 else { return vlmElement }

            let overlappingOCRTexts = ocrBoxes.compactMap { ocrBox -> (String, CGFloat)? in
                guard ocrBox.pixelBoundingBox.count == 4 else { return nil }
                let ocrRect = CGRect(
                    x: ocrBox.pixelBoundingBox[0],
                    y: ocrBox.pixelBoundingBox[1],
                    width: ocrBox.pixelBoundingBox[2],
                    height: ocrBox.pixelBoundingBox[3]
                )
                let overlapFraction = overlapFraction(of: ocrRect, within: elementRect)
                guard overlapFraction > 0.5 else { return nil }
                // Sort by top-then-left so multi-line element text reads
                // in natural reading order, not random Vision order.
                return (ocrBox.text, ocrRect.minY * 10000 + ocrRect.minX)
            }

            guard !overlappingOCRTexts.isEmpty else { return vlmElement }

            let orderedText = overlappingOCRTexts
                .sorted { $0.1 < $1.1 }
                .map { $0.0 }
                .joined(separator: " ")

            return LocalVLMScreenElement(
                label: vlmElement.label,
                role: vlmElement.role,
                bbox: vlmElement.bbox,
                text: orderedText
            )
        }

        // Append any OCR boxes that didn't fall inside ANY VLM element
        // as standalone "static_text" entries — so the planner can see
        // text the VLM missed entirely (small text, code in margins).
        let elementRectsForOverlapTest = vlmAnalysis.elements.compactMap { vlmElement -> CGRect? in
            guard vlmElement.bbox.count == 4 else { return nil }
            return CGRect(
                x: vlmElement.bbox[0], y: vlmElement.bbox[1],
                width: vlmElement.bbox[2], height: vlmElement.bbox[3]
            )
        }

        let orphanOCRElements: [LocalVLMScreenElement] = ocrBoxes.compactMap { ocrBox in
            guard ocrBox.pixelBoundingBox.count == 4 else { return nil }
            let ocrRect = CGRect(
                x: ocrBox.pixelBoundingBox[0], y: ocrBox.pixelBoundingBox[1],
                width: ocrBox.pixelBoundingBox[2], height: ocrBox.pixelBoundingBox[3]
            )
            let isAlreadyCovered = elementRectsForOverlapTest.contains { vlmRect in
                overlapFraction(of: ocrRect, within: vlmRect) > 0.5
            }
            guard !isAlreadyCovered else { return nil }
            return LocalVLMScreenElement(
                label: String(ocrBox.text.prefix(40)),
                role: "static_text",
                bbox: ocrBox.pixelBoundingBox,
                text: ocrBox.text
            )
        }

        // Cap the orphan list so a noisy page doesn't blow the prompt.
        // 30 extras is plenty of additional verbatim text without
        // overwhelming the element list.
        let cappedOrphans = Array(orphanOCRElements.prefix(30))

        return LocalVLMScreenAnalysis(
            elements: enrichedElements + cappedOrphans,
            description: vlmAnalysis.description
        )
    }

    /// Fraction of `inner`'s area that falls inside `container`. Used
    /// as the matching threshold so a tiny OCR box inside a large
    /// element counts as "this text belongs to that element" while a
    /// partial overlap doesn't.
    nonisolated private static func overlapFraction(of inner: CGRect, within container: CGRect) -> CGFloat {
        let intersection = inner.intersection(container)
        guard !intersection.isNull, inner.width > 0, inner.height > 0 else { return 0 }
        let innerArea = inner.width * inner.height
        let intersectionArea = intersection.width * intersection.height
        return intersectionArea / innerArea
    }
}
