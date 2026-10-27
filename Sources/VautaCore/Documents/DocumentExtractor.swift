// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Reads a file's text. The protocol takes a file and a format and returns plain data, so the reader can later move to a
/// separate, sandboxed process without anything else changing.
public protocol DocumentExtracting: Sendable {
    /// The text of `url`. Pages and images that need OCR are reported (`pagesNeedingOCR`, an empty result for an image)
    /// and read later by `recognize`, so text documents become searchable first.
    func extract(_ url: URL, format: DocumentFormat) async throws -> ExtractedDocument
    /// The text of the pages of a PDF (`pages`, 1-based) or of an image (`pages` ignored), read with OCR.
    func recognize(_ url: URL, format: DocumentFormat, pages: [Int]) async throws -> [DocumentUnit]
}

/// The extractor of this app: Apple frameworks and the readers in this folder.
public struct DocumentExtractor: DocumentExtracting {
    public init() {}

    public func extract(_ url: URL, format hint: DocumentFormat) async throws -> ExtractedDocument {
        // The parsers are synchronous and some are Apple's: they run on a thread of their own, so one that never returns cannot
        // hold the cooperative pool (the indexer's deadline abandons it).
        try await runOnDedicatedThread { try Self.extractSync(url, format: hint) }
    }

    static func extractSync(_ url: URL, format hint: DocumentFormat) throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= DocumentLimits.maxBytes(for: hint) else { throw DocumentExtractionError(.tooLarge) }
        // What the file is decides, not its name: a `.pdf` that is a ZIP is read as one.
        let format = try FormatSniffer.sniff(url, hint: hint)
        let clock = ExtractionClock(seconds: DocumentLimits.textExtractionSeconds)
        switch format {
        case .pdf:
            return try PDFExtractor.extract(url, clock: clock)
        case .docx, .pptx, .xlsx:
            let data = try Self.read(url, limit: DocumentLimits.maxOfficeBytes)
            if OOXML.isEncryptedCompoundFile(data) { throw DocumentExtractionError(.passwordProtected) }
            let zip = try SafeZip(data: data)
            switch OOXML.kind(of: zip) {
            case .docx: return try DOCXReader.read(zip, clock: clock)
            case .pptx: return try PPTXReader.read(zip, clock: clock)
            case .xlsx: return try XLSXReader.read(zip, clock: clock)
            case .other: throw DocumentExtractionError(.unreadable)
            }
        case .doc:
            if OOXML.isEncryptedCompoundFile(try Self.read(url, limit: DocumentLimits.maxOfficeBytes)) { throw DocumentExtractionError(.passwordProtected) }
            return try TextExtractors.attributed(url, type: .docFormat, clock: clock)
        case .rtf:
            return try TextExtractors.attributed(url, type: .rtf, clock: clock)
        case .html:
            let data = try Self.read(url, limit: DocumentLimits.maxTextBytes)
            guard let text = TextDecoding.decode(data, hint: TextDecoding.declaredHTMLEncoding(data)) else { throw DocumentExtractionError(.unsupported) }
            return try HTMLText.extract(text, clock: clock)
        case .markdown, .text, .csv, .tsv:
            let data = try Self.read(url, limit: DocumentLimits.maxTextBytes)
            guard let text = TextDecoding.decode(data) else { throw DocumentExtractionError(.unsupported) }
            switch format {
            case .markdown: return try TextExtractors.markdown(text, clock: clock)
            case .csv: return try TextExtractors.table(text, delimiter: ",", name: "", clock: clock)
            case .tsv: return try TextExtractors.table(text, delimiter: "\t", name: "", clock: clock)
            default: return try TextExtractors.plain(text, clock: clock)
            }
        case .image:
            guard let pixels = VisionOCR.pixelSize(of: url) else { throw DocumentExtractionError(.unreadable) }
            guard pixels.width * pixels.height <= DocumentLimits.maxImagePixels else { throw DocumentExtractionError(.tooLarge) }
            guard max(pixels.width, pixels.height) >= DocumentLimits.minImageSide else { throw DocumentExtractionError(.noText) }
            // The pixels are read in the OCR pass.
            return ExtractedDocument(units: [], pagesNeedingOCR: [1])
        }
    }

    public func recognize(_ url: URL, format: DocumentFormat, pages: [Int]) async throws -> [DocumentUnit] {
        let clock = ExtractionClock(seconds: VisionOCR.pageDeadline + DocumentLimits.ocrPageSeconds * Double(max(1, min(pages.count, DocumentLimits.maxOCRPagesPerFile))))
        switch format {
        case .pdf:
            return try await PDFExtractor.recognize(url, pages: pages, clock: clock)
        case .image:
            let text = TextSanitizer.tidy(TextSanitizer.clean(try await VisionOCR.text(ofImageAt: url)))
            guard text.filter({ !$0.isWhitespace }).count >= DocumentLimits.minimumOCRCharacters else { throw DocumentExtractionError(.noText) }
            return [DocumentUnit(locator: .image, text: text, ocr: true)]
        default:
            return []
        }
    }

    /// The first `count` bytes of a file.
    static func readPrefix(_ url: URL, count: Int) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw DocumentExtractionError(.unreadable) }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: count)) ?? nil) ?? Data()
    }

    /// The bytes of a file, never mapped (a file that shrinks while it is read must not crash Vauta), and never more than `limit`.
    static func read(_ url: URL, limit: Int64) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw DocumentExtractionError(.unreadable) }
        defer { try? handle.close() }
        let data: Data?
        do { data = try handle.read(upToCount: Int(limit) + 1) } catch { throw DocumentExtractionError(.unreadable) }
        // An empty file reads as no data at all.
        guard let data else { return Data() }
        guard data.count <= Int(limit) else { throw DocumentExtractionError(.tooLarge) }
        return data
    }
}

/// What a file really is, from its first bytes.
enum FormatSniffer {
    static func sniff(_ url: URL, hint: DocumentFormat) throws -> DocumentFormat {
        let head = try DocumentExtractor.readPrefix(url, count: 16)
        let bytes = [UInt8](head)
        if bytes.starts(with: Array("%PDF".utf8)) { return .pdf }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            // An Office file is a ZIP: the hint says which one (the archive's own entries confirm it when it is read).
            return [.docx, .pptx, .xlsx].contains(hint) ? hint : .docx
        }
        if bytes.starts(with: Array("{\\rtf".utf8)) { return .rtf }
        if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return hint == .docx || hint == .pptx || hint == .xlsx ? hint : .doc }
        if isImage(bytes) { return .image }
        // Text formats: the file must not claim to be a binary format.
        switch hint {
        case .pdf, .docx, .pptx, .xlsx, .doc, .rtf, .image: throw DocumentExtractionError(.unreadable)
        default: return hint
        }
    }

    private static func isImage(_ b: [UInt8]) -> Bool {
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) || b.starts(with: [0xFF, 0xD8, 0xFF]) || b.starts(with: Array("GIF8".utf8)) { return true }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        if b.starts(with: Array("BM".utf8)) { return true }
        if b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WEBP".utf8) { return true }
        // HEIC and HEIF: an `ftyp` box.
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) { return true }
        return false
    }
}
