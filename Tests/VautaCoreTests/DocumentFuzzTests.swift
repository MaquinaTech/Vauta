// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A small deterministic generator, so a failing input can be reproduced from its seed and iteration.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Runs heavy synchronous test work on a thread of its own, so it never holds one of the cooperative pool's few threads while
/// other suites' timing tests run alongside it. The closure returns what the test then checks: `#expect` stays on the test's task.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await runOnDedicatedThread(body)
}

enum Fuzz {
    /// 5,000 in CI; `VAUTA_FUZZ_ITERATIONS` raises it for a local run.
    static var iterations: Int { ProcessInfo.processInfo.environment["VAUTA_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 5_000 }

    /// A few random edits: flips, replacements, insertions, deletions, a truncation or a duplicated stretch.
    static func mutate(_ data: Data, _ rng: inout SeededGenerator) -> Data {
        var bytes = [UInt8](data)
        guard !bytes.isEmpty else { return data }
        for _ in 0..<Int.random(in: 1...8, using: &rng) {
            let i = Int.random(in: 0..<bytes.count, using: &rng)
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: bytes[i] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            case 1: bytes[i] = UInt8.random(in: 0...255, using: &rng)
            case 2: bytes.insert(UInt8.random(in: 0...255, using: &rng), at: i)
            case 3: if bytes.count > 1 { bytes.remove(at: i) }
            case 4: bytes = Array(bytes.prefix(max(1, i)))
            default:
                let n = min(Int.random(in: 1...32, using: &rng), bytes.count - i)
                bytes.insert(contentsOf: bytes[i..<(i + n)], at: i)
            }
            if bytes.isEmpty { break }
        }
        return Data(bytes)
    }
}

@Suite struct SafeZipFuzzTests {
    @Test func mutatedOfficeFilesNeverCrashHangOrEscapeTheLimits() async throws {
        let (opened, seconds) = try await offPool { () -> (Int, TimeInterval) in
            let seeds: [Data] = [
                OfficeFixtures.docx(body: OfficeFixtures.para("Heading", style: "Heading1") + OfficeFixtures.para("Body text of the document.")),
                OfficeFixtures.pptx(slides: [("Slide one", "Notes"), ("Slide two", nil)]),
                OfficeFixtures.xlsx(sheets: [(name: "S", visible: true, rows: [["A", "B"], ["x", 1], ["y", 2]])]),
            ]
            var rng = SeededGenerator(seed: 42)
            let start = Date()
            var opened = 0
            for i in 0..<Fuzz.iterations {
                let data = Fuzz.mutate(seeds[i % seeds.count], &rng)
                guard let zip = try? SafeZip(data: data) else { continue }
                opened += 1
                let clock = ExtractionClock(seconds: 5)
                switch OOXML.kind(of: zip) {
                case .docx: _ = try? DOCXReader.read(zip, clock: clock)
                case .pptx: _ = try? PPTXReader.read(zip, clock: clock)
                case .xlsx: _ = try? XLSXReader.read(zip, clock: clock)
                case .other: break
                }
                for name in zip.names.prefix(10) { _ = try? zip.read(name) }
            }
            return (opened, Date().timeIntervalSince(start))
        }
        #expect(opened > 0, "some mutations still open (the fuzzer reaches the readers)")
        #expect(seconds < 120, "no input made it hang")
    }
}

@Suite struct SafeXMLFuzzTests {
    @Test func mutatedXMLEndsInADocumentOrAnError() async throws {
        let (parsed, unexpected) = try await offPool { () -> (Int, [String]) in
            let seed = Data(#"<?xml version="1.0"?><w:document xmlns:w="w"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>"#.utf8)
            var rng = SeededGenerator(seed: 7)
            var parsed = 0
            var unexpected: [String] = []
            var limits = SafeXML.Limits()
            limits.deadline = Date().addingTimeInterval(120)
            for _ in 0..<Fuzz.iterations {
                let data = Fuzz.mutate(seed, &rng)
                var elements = 0
                do {
                    try SafeXML.parse(data, limits: limits, start: { _, _ in elements += 1 })
                    parsed += 1
                } catch let error as DocumentExtractionError {
                    if !(error.reason == .unreadable || error.reason == .tooLarge || error.reason == .timedOut) { unexpected.append("\(error.reason)") }
                } catch {
                    unexpected.append("\(error)")
                }
            }
            return (parsed, unexpected)
        }
        #expect(parsed > 0)
        #expect(unexpected.isEmpty, "unexpected errors: \(unexpected.prefix(5))")
    }

    @Test func mutatedTextFormatsNeverCrash() async throws {
        try await offPool {
        let seeds = [Data("# Title\n\nSome **bold** text with a [link](https://example.com).\n".utf8),
                     Data("<html><head><title>T</title></head><body><h1>Head</h1><p>Text &amp; more &#x41;</p><script>x</script></body></html>".utf8),
                     Data("a,b,c\n1,\"two, three\",4\n".utf8)]
        var rng = SeededGenerator(seed: 99)
        let clock = ExtractionClock(seconds: 5)
        for i in 0..<Fuzz.iterations {
            let data = Fuzz.mutate(seeds[i % seeds.count], &rng)
            guard let text = TextDecoding.decode(data) else { continue }
            switch i % 3 {
            case 0: _ = try? TextExtractors.markdown(text)
            case 1: _ = try? HTMLText.extract(text, clock: clock)
            default: _ = try? TextExtractors.table(text, delimiter: ",", name: "")
            }
        }
        }
    }
}
