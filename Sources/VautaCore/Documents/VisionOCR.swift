// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Vision

/// Text from pixels, on this Mac, with Vision. Nothing is written to disk and nothing leaves the Mac: the image only
/// lives in memory while it is read.
enum VisionOCR {
    /// The first request of a process loads and compiles the recognition model, which can take most of a minute on a Mac
    /// that has never run it (measured: 42 s, then 0.1 to 0.2 s per image). Until one request has finished, the deadline is long.
    private static let warmed = SharedValue(false)
    static var pageDeadline: TimeInterval { warmed.value ? DocumentLimits.ocrPageSeconds : 240 }

    /// The recognized text in reading order, or an empty string when there is none. Vision's document reader is used first
    /// (it joins the lines of a paragraph and keeps Japanese and Chinese free of stray spaces: on a sample of five scripts
    /// both read the same words, and this one read Japanese better); the plain text reader is the fallback.
    static func recognize(_ image: CGImage) async throws -> String {
        defer { warmed.set(true) }
        do {
            let documents = try await RecognizeDocumentsRequest().perform(on: image)
            let text = documents.map { $0.document.text.transcript }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        return try await recognizeLines(image)
    }

    /// The text reader: lines in reading order (top to bottom, then left to right).
    static func recognizeLines(_ image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        let ordered = observations.sorted { a, b in
            let (ra, rb) = (a.boundingBox.cgRect, b.boundingBox.cgRect)
            // Vision's origin is the bottom left: a higher y is higher on the page. Lines within half a line height are one row.
            if abs(ra.midY - rb.midY) > min(ra.height, rb.height) / 2 { return ra.midY > rb.midY }
            return ra.minX < rb.minX
        }
        return ordered.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// The pixel size of an image file without decoding it.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// The first frame of an image file, decoded at most `maxPixel` on the long side.
    static func thumbnail(of url: URL, maxPixel: Int = 4096) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    /// An image file's text.
    static func text(ofImageAt url: URL) async throws -> String {
        // ImageIO is synchronous and may wait on a slow disk: the decoding runs on a thread of its own, within the page deadline.
        let decoded = try await runWithDeadline(seconds: pageDeadline) { () -> DecodedImage in
            guard let size = pixelSize(of: url) else { throw DocumentExtractionError(.unreadable) }
            guard size.width * size.height <= DocumentLimits.maxImagePixels else { throw DocumentExtractionError(.tooLarge) }
            guard max(size.width, size.height) >= DocumentLimits.minImageSide else { throw DocumentExtractionError(.noText) }
            guard let image = thumbnail(of: url) else { throw DocumentExtractionError(.unreadable) }
            return DecodedImage(image: image)
        }
        let image = decoded.image
        return try await withDeadline(seconds: pageDeadline) { try await recognize(image) }
    }

    /// A decoded picture handed from the decoding thread to the recognizer, which only reads it.
    private struct DecodedImage: @unchecked Sendable { let image: CGImage }
}

/// A value shared between threads.
final class SharedValue<Value: Sendable>: Sendable {
    private let stored: Mutex<Value>
    init(_ value: Value) { stored = Mutex(value) }
    var value: Value { stored.withLock { $0 } }
    func set(_ new: Value) { stored.withLock { $0 = new } }
}
