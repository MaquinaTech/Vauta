// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import VautaCore

/// Resident memory of this process now, in bytes.
func residentMemory() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}

/// Hostile and malformed files: every one ends in a skip reason, within its time limit, with bounded memory.
@Suite(.serialized) struct HostileFileTests {
    let extractor = DocumentExtractor()
    private let memoryCeiling = 400 << 20

    private func outcome(_ name: String, _ data: Data, format: DocumentFormat, seconds: Double = 20) async -> (reason: DocumentSkipReason?, took: Double, growth: Int) {
        let folder = DocumentFolder()
        let url = folder.write(name, data)
        let before = residentMemory()
        let start = Date()
        var reason: DocumentSkipReason?
        do { _ = try await extractor.extract(url, format: format) } catch let e as DocumentExtractionError { reason = e.reason } catch { reason = .unreadable }
        return (reason, Date().timeIntervalSince(start), residentMemory() - before)
    }

    private func expectSkipped(_ name: String, _ data: Data, format: DocumentFormat, _ allowed: Set<DocumentSkipReason> = [.unreadable],
                               sourceLocation: SourceLocation = #_sourceLocation) async {
        let result = await outcome(name, data, format: format)
        #expect(result.reason.map(allowed.contains) == true, "reason \(String(describing: result.reason))", sourceLocation: sourceLocation)
        #expect(result.took < Double(DocumentLimits.textExtractionSeconds), sourceLocation: sourceLocation)
        #expect(result.growth < memoryCeiling, "grew \(result.growth >> 20) MB", sourceLocation: sourceLocation)
    }

    private func docx(_ mutate: (inout ZipBuilder) -> Void) -> Data {
        var zip = ZipBuilder()
        zip.add("[Content_Types].xml", OfficeFixtures.contentTypes)
        mutate(&zip)
        if !zip.items.contains(where: { $0.name == "word/document.xml" }) {
            zip.add("word/document.xml", "<w:document xmlns:w=\"w\"><w:body>\(OfficeFixtures.para("hello"))</w:body></w:document>")
        }
        return zip.build()
    }

    // MARK: ZIP

    @Test func aZipBombByRatioIsRejectedWithoutInflatingIt() async {
        var zip = ZipBuilder()
        zip.add("word/document.xml", String(repeating: "A", count: 40 << 20))
        await expectSkipped("bomb.docx", zip.build(), format: .docx)
    }

    @Test func anEntryLargerThanItsDeclaredSizeIsRejected() async {
        var zip = ZipBuilder()
        zip.add(.init(name: "word/document.xml", data: Data(String(repeating: "<w:p/>", count: 10_000).utf8), deflate: true, declaredSize: 100))
        await expectSkipped("lie.docx", zip.build(), format: .docx)
    }

    @Test func aNestedArchiveIsNeverOpened() async throws {
        var inner = ZipBuilder()
        inner.add("word/document.xml", "<w:document xmlns:w=\"w\"><w:body>\(OfficeFixtures.para("INNER SECRET"))</w:body></w:document>")
        let data = docx { zip in zip.add(.init(name: "word/embeddings/nested.docx", data: inner.build(), deflate: false)) }
        let folder = DocumentFolder()
        let doc = try await extractor.extract(folder.write("n.docx", data), format: .docx)
        #expect(!doc.units.map(\.text).joined().contains("INNER SECRET"))
    }

    @Test func anArchiveWithTooManyEntriesIsRejected() async {
        var zip = ZipBuilder()
        for i in 0..<5_100 { zip.add(.init(name: "e\(i).xml", data: Data("x".utf8), deflate: false)) }
        await expectSkipped("many.docx", zip.build(), format: .docx)
    }

    @Test func zip64IsRejected() async {
        var zip = ZipBuilder()
        zip.add("word/document.xml", "<w:document xmlns:w=\"w\"/>")
        zip.zip64 = true
        await expectSkipped("z64.docx", zip.build(), format: .docx)
    }

    @Test func unsafeEntryNamesAreRejected() async {
        for name in ["../evil.xml", "/abs.xml", "a/../../b.xml", "bad\\name.xml"] {
            var zip = ZipBuilder()
            zip.add(.init(name: name, data: Data("x".utf8), deflate: false))
            await expectSkipped("names.docx", docx { $0 = zip }, format: .docx)
        }
    }

    @Test func duplicateNamesAreRejectedForTheEntryThatIsRead() async {
        let data = docx { zip in
            zip.add("word/document.xml", "<w:document xmlns:w=\"w\"><w:body>\(OfficeFixtures.para("first"))</w:body></w:document>")
            zip.add("word/document.xml", "<w:document xmlns:w=\"w\"><w:body>\(OfficeFixtures.para("second"))</w:body></w:document>")
        }
        await expectSkipped("dup.docx", data, format: .docx)
    }

    @Test func aLocalHeaderThatDisagreesWithTheDirectoryIsRejected() async {
        let data = docx { zip in zip.add(.init(name: "word/document.xml", data: Data("<w:document xmlns:w=\"w\"/>".utf8), localName: "word/other.xml")) }
        await expectSkipped("hdr.docx", data, format: .docx)
    }

    @Test func aCRCMismatchIsRejected() async {
        let data = docx { zip in zip.add(.init(name: "word/document.xml", data: Data("<w:document xmlns:w=\"w\"/>".utf8), crc: 0xDEADBEEF)) }
        await expectSkipped("crc.docx", data, format: .docx)
    }

    @Test func aTruncatedArchiveIsRejected() async {
        let full = OfficeFixtures.docx(body: OfficeFixtures.para("hello there"))
        await expectSkipped("cut.docx", full.dropLast(40), format: .docx)
        await expectSkipped("half.docx", full.prefix(full.count / 2), format: .docx)
        await expectSkipped("empty.docx", Data(), format: .docx)
    }

    @Test func anEncryptedEntryIsPasswordProtected() async {
        let data = docx { zip in zip.add(.init(name: "word/document.xml", data: Data("x".utf8), deflate: false, flags: 1)) }
        await expectSkipped("enc.docx", data, format: .docx, [.passwordProtected])
    }

    // MARK: XML

    private func docxWithBody(xml: String) -> Data {
        var zip = ZipBuilder()
        zip.add("[Content_Types].xml", OfficeFixtures.contentTypes)
        zip.add("word/document.xml", xml)
        return zip.build()
    }

    @Test func aDoctypeAndExternalEntitiesAreRefused() async {
        let xxe = #"<?xml version="1.0"?><!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/passwd">]><w:document xmlns:w="w"><w:body><w:p><w:r><w:t>&x;</w:t></w:r></w:p></w:body></w:document>"#
        await expectSkipped("xxe.docx", docxWithBody(xml: xxe), format: .docx)
        let laughs = #"<?xml version="1.0"?><!DOCTYPE l [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;">]><w:document xmlns:w="w"><w:body><w:p><w:r><w:t>&c;</w:t></w:r></w:p></w:body></w:document>"#
        await expectSkipped("laughs.docx", docxWithBody(xml: laughs), format: .docx)
    }

    @Test func deepNestingIsRefused() async {
        let deep = "<w:document xmlns:w=\"w\"><w:body>" + String(repeating: "<w:sdt>", count: 10_000) + String(repeating: "</w:sdt>", count: 10_000) + "</w:body></w:document>"
        await expectSkipped("deep.docx", docxWithBody(xml: deep), format: .docx)
    }

    @Test func anEnormousTextNodeIsRefusedOrBounded() async {
        let huge = "<w:document xmlns:w=\"w\"><w:body><w:p><w:r><w:t>" + String(repeating: "word ", count: 2_000_000) + "</w:t></w:r></w:p></w:body></w:document>"
        let result = await outcome("huge.docx", docxWithBody(xml: huge), format: .docx)
        // Either refused as too large, or read with a partial flag; never unbounded.
        #expect(result.growth < memoryCeiling && result.took < Double(DocumentLimits.textExtractionSeconds))
        #expect(result.reason == .tooLarge || result.reason == .unreadable || result.reason == nil)
    }

    // MARK: PDF, images and plain files

    @Test func brokenPDFsAreRejected() async {
        let good = PDFFixtures.make(pages: ["Some words on a page that are long enough to count as text for the reader."])
        await expectSkipped("cut.pdf", good.prefix(good.count / 2), format: .pdf, [.unreadable, .noText])
        await expectSkipped("zero.pdf", Data(), format: .pdf)
        let cyclic = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[2 0 R]/Count 1>>endobj\nxref\n0 3\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \ntrailer<</Root 1 0 R/Size 3/Prev 116>>\nstartxref\n116\n%%EOF"
        await expectSkipped("cyclic.pdf", Data(cyclic.utf8), format: .pdf, [.unreadable, .noText, .timedOut])
    }

    @Test func aPDFThatDeclaresAHundredThousandPagesIsBounded() async {
        let pdf = "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 100000>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 100 100]>>endobj\ntrailer<</Root 1 0 R/Size 4>>\n%%EOF"
        await expectSkipped("many.pdf", Data(pdf.utf8), format: .pdf, [.unreadable, .noText, .timedOut])
    }

    @Test func anImageThatDeclaresFiftyThousandPixelsEachWayIsTooLarge() async {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let crc = SafeZip.crc32(Data(type.utf8 + body))
            let length = UInt32(body.count)
            return withUnsafeBytes(of: length.bigEndian) { Array($0) } + Array(type.utf8) + body + withUnsafeBytes(of: crc.bigEndian) { Array($0) }
        }
        let width = UInt32(50_000).bigEndian, height = UInt32(50_000).bigEndian
        let ihdr = withUnsafeBytes(of: width) { Array($0) } + withUnsafeBytes(of: height) { Array($0) } + [8, 2, 0, 0, 0]
        let png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IEND", [])
        await expectSkipped("huge.png", Data(png), format: .image, [.tooLarge, .unreadable])
    }

    @Test func aHugeSparseTextFileIsTooLargeAndNeverRead() async throws {
        let folder = DocumentFolder()
        let url = folder.write("sparse.txt", "x")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()
        let before = residentMemory()
        do { _ = try await extractor.extract(url, format: .text); Issue.record("should not read") } catch let e as DocumentExtractionError { #expect(e.reason == .tooLarge) }
        #expect(residentMemory() - before < memoryCeiling)
    }

    @Test func aFileThatChangesWhileItIsReadIsReadAgainNeverHalfAndHalf() async throws {
        struct Changing: DocumentExtracting {
            let target: URL
            let state = SharedValue(0)
            func extract(_ url: URL, format: DocumentFormat) async throws -> ExtractedDocument {
                let n = state.value
                state.set(n + 1)
                let text = n == 0 ? "Original words about the first version of the memo." : "Replacement words about the second version of the memo."
                if n == 0 {
                    // The file is rewritten while the first read is under way.
                    try Data("A completely different and longer second version of the memo, written mid-read.".utf8).write(to: target)
                }
                return try TextExtractors.plain(text)
            }
            func recognize(_ url: URL, format: DocumentFormat, pages: [Int]) async throws -> [DocumentUnit] { [] }
        }
        let fx = try DocsFixture()
        let file = fx.files.write("memo.txt", "Original words about the first version of the memo.")
        let changing = Changing(target: file)
        try await fx.open(extractor: changing)
        try await fx.add()
        #expect(changing.state.value == 2, "read twice: the first read raced a change")
        let hits = try await fx.search("memo version")
        #expect(hits.count == 1)
        #expect(hits.first?.text.contains("Replacement words") == true, "the second read, never the first")
    }

    @Test func aFileMissingWhenItsTurnComesIsDroppedQuietly() async throws {
        let fx = try DocsFixture()
        let file = fx.files.write("vanishing.txt", "Text about a file that is deleted before it is read.")
        try await fx.open()
        await fx.indexer.stop()
        let source = try await fx.meetingStore.addDocumentSource(kind: .folder, displayName: "x", path: fx.files.url.path, bookmark: Data(fx.files.url.path.utf8), volumeUUID: nil)
        for scanned in DocumentScanner.scan(fx.files.url, kind: .folder).files { try await fx.index.markPending(source: source.id, scanned: scanned, format: .text) }
        try FileManager.default.removeItem(at: file)
        await fx.indexer.start(background: false)
        try await fx.settle()
        #expect(try await fx.index.totalFiles() == 0)
    }
}
