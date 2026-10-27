// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Compression
import CoreText
import Foundation
import Testing
@testable import VautaCore

/// A temporary folder removed on deinit. Document tests build every file they read: no real documents are used.
final class DocumentFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-docs-test-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ name: String, _ data: Data) -> URL {
        let file = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
        return file
    }

    @discardableResult
    func write(_ name: String, _ text: String) -> URL { write(name, Data(text.utf8)) }
}

/// Builds ZIP files for the tests, including deliberately broken ones.
struct ZipBuilder {
    struct Item {
        var name: String
        var data: Data
        var deflate = true
        var declaredSize: Int?
        var crc: UInt32?
        var flags: UInt16 = 0
        var localName: String?
    }

    var items: [Item] = []
    var zip64 = false

    mutating func add(_ name: String, _ text: String, deflate: Bool = true) { items.append(Item(name: name, data: Data(text.utf8), deflate: deflate)) }
    mutating func add(_ item: Item) { items.append(item) }

    static func deflated(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var out = [UInt8](repeating: 0, count: data.count + data.count / 8 + 1024)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(out[0..<n])
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    func build() -> Data {
        var out = Data()
        var central = Data()
        for item in items {
            let payload = item.deflate ? Self.deflated(item.data) : item.data
            let method: UInt16 = item.deflate ? 8 : 0
            let crc = item.crc ?? SafeZip.crc32(item.data)
            let size = UInt32(item.declaredSize ?? item.data.count)
            let nameBytes = Array((item.localName ?? item.name).utf8)
            let centralName = Array(item.name.utf8)
            let offset = UInt32(out.count)
            out.append(contentsOf: le32(0x0403_4B50) + le16(20) + le16(item.flags) + le16(method) + le16(0) + le16(0)
                       + le32(crc) + le32(UInt32(payload.count)) + le32(size) + le16(UInt16(nameBytes.count)) + le16(0))
            out.append(contentsOf: nameBytes)
            out.append(payload)
            central.append(contentsOf: le32(0x0201_4B50) + le16(20) + le16(20) + le16(item.flags) + le16(method) + le16(0) + le16(0)
                           + le32(crc) + le32(UInt32(payload.count)) + le32(size) + le16(UInt16(centralName.count)) + le16(0) + le16(0)
                           + le16(0) + le16(0) + le32(0) + le32(offset))
            central.append(contentsOf: centralName)
        }
        let directoryOffset = UInt32(out.count)
        out.append(central)
        if zip64 { out.append(contentsOf: le32(0x0706_4B50) + [UInt8](repeating: 0, count: 16)) }
        let count = UInt16(truncatingIfNeeded: items.count)
        out.append(contentsOf: le32(0x0605_4B50) + le16(0) + le16(0) + le16(count) + le16(count) + le32(UInt32(central.count))
                   + le32(directoryOffset) + le16(0))
        return out
    }
}

/// Tiny Office files made in memory.
enum OfficeFixtures {
    static let contentTypes = #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"></Types>"#

    static func docx(body: String, styles: String? = nil, title: String? = nil) -> Data {
        var zip = ZipBuilder()
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("word/document.xml", #"<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"# + body + "</w:body></w:document>")
        if let styles { zip.add("word/styles.xml", styles) }
        if let title { zip.add("docProps/core.xml", #"<cp:coreProperties xmlns:cp="x" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>"# + title + "</dc:title></cp:coreProperties>") }
        return zip.build()
    }

    static func para(_ text: String, style: String? = nil, hidden: Bool = false) -> String {
        let pPr = style.map { #"<w:pPr><w:pStyle w:val="\#($0)"/></w:pPr>"# } ?? ""
        let rPr = hidden ? "<w:rPr><w:vanish/></w:rPr>" : ""
        return "<w:p>\(pPr)<w:r>\(rPr)<w:t>\(text)</w:t></w:r></w:p>"
    }

    static func pptx(slides: [(String, String?)]) -> Data {
        var zip = ZipBuilder()
        zip.add("[Content_Types].xml", contentTypes)
        var ids = "", rels = ""
        for (i, slide) in slides.enumerated() {
            let n = i + 1
            ids += #"<p:sldId id="\#(255 + n)" r:id="rId\#(n)"/>"#
            rels += #"<Relationship Id="rId\#(n)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#(n).xml"/>"#
            zip.add("ppt/slides/slide\(n).xml", #"<p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>"# + slide.0 + "</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>")
            if let notes = slide.1 {
                zip.add("ppt/slides/_rels/slide\(n).xml.rels", #"<Relationships xmlns="r"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide\#(n).xml"/></Relationships>"#)
                zip.add("ppt/notesSlides/notesSlide\(n).xml", #"<p:notes xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>"# + notes + "</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>")
            }
        }
        // The slides are listed in the order of the presentation, which is reversed here to prove the order is read.
        zip.add("ppt/presentation.xml", #"<p:presentation xmlns:p="p" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst>"# + ids + "</p:sldIdLst></p:presentation>")
        zip.add("ppt/_rels/presentation.xml.rels", #"<Relationships xmlns="r">"# + rels + "</Relationships>")
        return zip.build()
    }

    /// `sheets`: name, visible, rows of cells (strings are shared strings, numbers are written as numbers).
    static func xlsx(sheets: [(name: String, visible: Bool, rows: [[Any]])], inlineStrings: Bool = false) -> Data {
        var zip = ZipBuilder()
        zip.add("[Content_Types].xml", contentTypes)
        var shared: [String] = []
        var workbook = "", rels = ""
        for (i, sheet) in sheets.enumerated() {
            let n = i + 1
            workbook += #"<sheet name="\#(sheet.name)" sheetId="\#(n)" state="\#(sheet.visible ? "visible" : "hidden")" r:id="rId\#(n)"/>"#
            rels += #"<Relationship Id="rId\#(n)" Type="x" Target="worksheets/sheet\#(n).xml"/>"#
            var xml = #"<worksheet xmlns="s"><sheetData>"#
            for (r, row) in sheet.rows.enumerated() {
                xml += #"<row r="\#(r + 1)">"#
                for (c, cell) in row.enumerated() {
                    let ref = XLSXReader.letters(c + 1) + String(r + 1)
                    if let s = cell as? String {
                        if inlineStrings {
                            xml += #"<c r="\#(ref)" t="inlineStr"><is><t>\#(s)</t></is></c>"#
                        } else {
                            if !shared.contains(s) { shared.append(s) }
                            xml += #"<c r="\#(ref)" t="s"><v>\#(shared.firstIndex(of: s)!)</v></c>"#
                        }
                    } else {
                        xml += #"<c r="\#(ref)"><v>\#(cell)</v></c>"#
                    }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            zip.add("xl/worksheets/sheet\(n).xml", xml)
        }
        zip.add("xl/workbook.xml", #"<workbook xmlns="w" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"# + workbook + "</sheets></workbook>")
        zip.add("xl/_rels/workbook.xml.rels", #"<Relationships xmlns="r">"# + rels + "</Relationships>")
        if !shared.isEmpty { zip.add("xl/sharedStrings.xml", #"<sst xmlns="s">"# + shared.map { "<si><t>\($0)</t></si>" }.joined() + "</sst>") }
        return zip.build()
    }
}

/// PDFs drawn with Core Graphics and Core Text.
enum PDFFixtures {
    /// One page per string; an empty string draws an empty page; `scanned` pages carry the text as an image.
    static func make(pages: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
                let attributed = NSAttributedString(string: text, attributes: [.font: font])
                let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                let path = CGPath(rect: CGRect(x: 56, y: 56, width: 500, height: 680), transform: nil)
                CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A PDF whose single page is a raster picture of `text` (no text layer): what a scan is.
    static func scanned(text: String, size: CGSize = CGSize(width: 1200, height: 400)) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: CGSize(width: 612, height: 200))
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil),
              let image = textImage(text, size: size) else { return Data() }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func textImage(_ text: String, size: CGSize = CGSize(width: 1200, height: 400), fontSize: CGFloat = 72) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 40, y: 40, width: size.width - 80, height: size.height - 80), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

/// A source access without the sandbox: a bookmark is the path as bytes. Tests choose which sources are unplugged.
final class PlainAccess: SourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var gone = Set<Int64>()
    private(set) var begun = 0

    func setDisconnected(_ id: Int64, _ value: Bool) { lock.withLock { if value { gone.insert(id) } else { gone.remove(id) } } }

    func makeBookmark(for url: URL) throws -> (data: Data, volumeUUID: String?) { (Data(url.path.utf8), "TEST-VOLUME") }

    func resolve(_ source: DocumentSource) -> SourceResolution {
        if lock.withLock({ gone.contains(source.id) }) { return .disconnected }
        let path = String(decoding: source.bookmark, as: UTF8.self)
        return FileManager.default.fileExists(atPath: path) ? .resolved(url: URL(fileURLWithPath: path), renewed: nil) : .notFound
    }

    func begin(_ url: URL) -> Bool { lock.withLock { begun += 1 }; return true }
    func end(_ url: URL) {}
}

/// An extractor that records what it was asked and can be told to fail or to take long.
final class RecordingExtractor: DocumentExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var extracted: [String] = []
    var failures: [String: DocumentSkipReason] = [:]
    var delay: Duration?
    let real = DocumentExtractor()

    func extract(_ url: URL, format: DocumentFormat) async throws -> ExtractedDocument {
        lock.withLock { extracted.append(url.lastPathComponent) }
        if let delay { try await Task.sleep(for: delay) }
        if let reason = lock.withLock({ failures[url.lastPathComponent] }) { throw DocumentExtractionError(reason) }
        return try await real.extract(url, format: format)
    }

    func recognize(_ url: URL, format: DocumentFormat, pages: [Int]) async throws -> [DocumentUnit] {
        try await real.recognize(url, format: format, pages: pages)
    }

    var count: Int { lock.withLock { extracted.count } }
    func times(_ name: String) -> Int { lock.withLock { extracted.filter { $0 == name }.count } }
}

/// A store, a documents index, an indexer and the folder of files they read.
final class DocsFixture {
    let store: StoreFixture
    let files = DocumentFolder()
    let access = PlainAccess()
    let extractor = RecordingExtractor()
    var meetingStore: MeetingStore!
    var index: DocumentIndex!
    var indexer: DocumentIndexer!
    var environment = SharedValue(IndexerEnvironment())

    init() throws {
        store = StoreFixture()
        meetingStore = try store.open()
    }

    func open(extractor override: (any DocumentExtracting)? = nil) async throws {
        index = try DocumentIndex(directory: await meetingStore.storeDirectory, key: await meetingStore.documentsKey())
        let env = environment
        indexer = DocumentIndexer(store: meetingStore, index: index, access: access, extractor: override ?? extractor, environment: { env.value })
        await indexer.start(background: false)
    }

    /// Adds `files` (or a sub folder of it) as a source and waits until nothing is pending.
    @discardableResult
    func add(folder name: String? = nil) async throws -> DocumentSource {
        let url = name.map { files.url.appendingPathComponent($0) } ?? files.url
        let source = try await indexer.addSource(url, isDirectory: true)
        try await settle()
        return source
    }

    func settle(timeout: Duration = .seconds(240)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let snapshot = await indexer.snapshot()
            if snapshot.pendingFiles == 0, snapshot.sources.allSatisfy({ $0.counts.ocrPending == 0 || !snapshot.ocrEnabled }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the indexer did not settle")
    }

    func search(_ question: String, filter: DocumentFilter? = nil, limit: Int = 8) async throws -> [DocumentPassage] {
        try await index.search(question, within: filter, limit: limit, locale: Locale(identifier: "en"))
    }
}
