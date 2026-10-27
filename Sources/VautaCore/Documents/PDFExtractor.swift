// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import PDFKit

/// PDF with PDFKit: one unit per page. A page with almost no text of its own (a scan) is read with OCR in a second pass.
enum PDFExtractor {
    static func extract(_ url: URL, clock: ExtractionClock) throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else { throw DocumentExtractionError(.unreadable) }
        if document.isLocked {
            // A file with only an owner password opens with the empty user password.
            guard document.unlock(withPassword: "") else { throw DocumentExtractionError(.passwordProtected) }
        }
        var units: [DocumentUnit] = []
        var needsOCR: [Int] = []
        var partial = false
        var characters = 0
        let count = document.pageCount
        guard count > 0 else { throw DocumentExtractionError(.unreadable) }
        for index in 0..<min(count, DocumentLimits.maxPDFPages) {
            try clock.check()
            guard let page = document.page(at: index) else { continue }
            let text = TextSanitizer.tidy(TextSanitizer.clean(page.string ?? ""))
            if text.filter({ !$0.isWhitespace }).count < DocumentLimits.scannedPageCharacters {
                needsOCR.append(index + 1)
                if !text.isEmpty { units.append(DocumentUnit(locator: .page(index + 1), text: text)) }
                continue
            }
            if characters + text.count > DocumentLimits.maxCharactersPerFile { partial = true; break }
            characters += text.count
            units.append(DocumentUnit(locator: .page(index + 1), text: text))
        }
        if count > DocumentLimits.maxPDFPages { partial = true }
        var title: String?
        if let raw = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let clean = TextSanitizer.oneLine(raw, limit: 160)
            if !clean.isEmpty { title = clean }
        }
        return ExtractedDocument(title: title, units: units, partial: partial, pagesNeedingOCR: needsOCR)
    }

    /// Pages rendered together on one dedicated thread (bounds the memory of the images held at once).
    static let renderGroup = 5

    /// A rendered page. `CGImage` is immutable; it only crosses from the render thread to the caller.
    struct RenderedPage: @unchecked Sendable {
        let number: Int
        let image: CGImage
    }

    /// Reads the given pages (1-based) with OCR. A page that cannot be rendered or has no text is left out. Opening the file and
    /// drawing its pages (PDFKit, which never looks at a clock) run on a thread of their own, so a crafted page cannot hold the
    /// cooperative pool; the caller's deadline abandons it.
    static func recognize(_ url: URL, pages: [Int], clock: ExtractionClock) async throws -> [DocumentUnit] {
        var units: [DocumentUnit] = []
        let wanted = Array(pages.prefix(DocumentLimits.maxOCRPagesPerFile))
        var start = 0
        while start < wanted.count {
            try clock.check()
            let group = Array(wanted[start..<min(start + renderGroup, wanted.count)])
            start += group.count
            let rendered = try await runOnDedicatedThread { try renderPages(url, pages: group, clock: clock) }
            for page in rendered {
                try clock.check()
                let image = page.image
                let text = TextSanitizer.tidy(TextSanitizer.clean(try await withDeadline(seconds: VisionOCR.pageDeadline) {
                    try await VisionOCR.recognize(image)
                }))
                if text.filter({ !$0.isWhitespace }).count >= DocumentLimits.minimumOCRCharacters {
                    units.append(DocumentUnit(locator: .page(page.number), text: text, ocr: true))
                }
            }
        }
        return units
    }

    private static func renderPages(_ url: URL, pages: [Int], clock: ExtractionClock) throws -> [RenderedPage] {
        guard let document = PDFDocument(url: url) else { throw DocumentExtractionError(.unreadable) }
        if document.isLocked, !document.unlock(withPassword: "") { throw DocumentExtractionError(.passwordProtected) }
        var result: [RenderedPage] = []
        for number in pages {
            try clock.check()
            guard let page = document.page(at: number - 1), let image = render(page) else { continue }
            result.append(RenderedPage(number: number, image: image))
        }
        return result
    }

    /// A page as an image: about 200 dpi, never more than 3,000 pixels on the long side.
    static func render(_ page: PDFPage) -> CGImage? {
        var box = page.bounds(for: .mediaBox)
        if page.rotation % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = min(200.0 / 72.0, 3_000.0 / max(box.width, box.height))
        let size = NSSize(width: (box.width * scale).rounded(.up), height: (box.height * scale).rounded(.up))
        let image = page.thumbnail(of: size, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
