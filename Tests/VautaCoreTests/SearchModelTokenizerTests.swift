// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
import VautaMLX
@testable import VautaCore

@Suite("Search model: tokenizer")
struct SearchModelTokenizerTests {
    @Test func mergesFollowTheRankOrderAndTheLeftmostWins() throws {
        let t = try TinyTokenizer.tokenizer()
        #expect(t.encodeBody("ab") == [8])
        #expect(t.encodeBody(" ab") == [9], "a+b first (rank 0), then the space symbol joins the result")
        #expect(t.encodeBody("abab") == [8, 8])
        #expect(t.encodeBody("a b") == [5, 4, 6], "spaces become the ▁ symbol, which can merge only where a merge says so")
    }

    @Test func unknownCharactersFallBackToBytesThenToUnk() throws {
        let t = try TinyTokenizer.tokenizer()
        #expect(t.encodeBody("ü") == [11, 12], "U+00FC is the bytes C3 BC, both in the vocabulary")
        #expect(t.encodeBody("zz") == [3], "unknown characters fuse into one <unk>")
        #expect(t.encodeBody("\n") == [13])
    }

    @Test func addedSpecialTokensAreMatchedInTheRawText() throws {
        let t = try TinyTokenizer.tokenizer()
        #expect(t.encodeBody("a<eos>b") == [5, 1, 6])
        #expect(t.encodeBody("<bos><eos>") == [2, 1])
        #expect(t.encodeBody("<bo") != [2], "a prefix of a special token is just text")
    }

    @Test func canonicallyEquivalentVocabularyKeysStayDistinct() throws {
        let t = try TinyTokenizer.tokenizer()
        // "é" (U+00E9) and "e" + U+0301 are equal as Swift Strings, but two different tokens.
        #expect("\u{e9}" == "e\u{301}")
        #expect(t.encodeBody("\u{e9}") == [20])
        #expect(t.encodeBody("e\u{301}") == [21])
    }

    @Test func encodeAddsBosAndEosAndTruncatesTheTailReportingIt() throws {
        let t = try TinyTokenizer.tokenizer()
        #expect(t.encode("").ids == [2, 1] && !t.encode("").truncated)
        let cut = t.encode("abababab", maxTokens: 4)
        #expect(cut.ids == [2, 8, 8, 1] && cut.truncated, "bos and eos always stay")
        #expect(t.encode("ab", maxTokens: 512).ids == [2, 8, 1])
        // A prompt is part of the text: the cut leaves room for it.
        #expect(t.encode("ab", prefix: "a", maxTokens: 512).ids == t.encode("aab").ids)
    }

    @Test func countEqualsTheBodyLength() throws {
        let t = try TinyTokenizer.tokenizer()
        for text in ["", "ab", "ab ab ab", "ü\nzz", "a<eos>b", "e\u{301}"] {
            #expect(t.count(text) == t.encodeBody(text).count)
            #expect(t.count(text, prefix: "ab ") == t.encodeBody("ab " + text).count)
        }
    }

    @Test func malformedTokenizersAreRefused() {
        for bad in ["", "{", "[]", "{\"model\":{}}", "{\"model\":{\"vocab\":{\"a\":1},\"merges\":[]}}"] {
            #expect(throws: GemmaTokenizerError.self) { try GemmaTokenizer(tokenizerJSON: Data(bad.utf8)) }
        }
    }

    /// Hugging Face's token ids for self-written strings (Italian, Portuguese, emoji, numbers, whitespace, special-token text,
    /// code, random Unicode), from the pinned tokenizer. Runs where a copy of the pinned `tokenizer.json` is on this Mac
    /// (`VAUTA_SEARCH_TOKENIZER`, or `tokenizer.json` in `VAUTA_SEARCH_MODEL_DIR`): tests never download it.
    @Test(.enabled(if: SearchModelTokenizerTests.pinnedTokenizerURL() != nil, "needs a copy of the pinned tokenizer.json: set VAUTA_SEARCH_TOKENIZER or VAUTA_SEARCH_MODEL_DIR"))
    func matchesHuggingFaceOnTheGoldens() throws {
        guard let url = Self.pinnedTokenizerURL() else { return }
        // Another revision would give token-id mismatches that look like a tokenizer bug: say what is wrong instead.
        do { try SearchModelVerifier.verifyTokenizer(file: url, spec: .pinned) } catch {
            Issue.record("\(url.path) is not the pinned tokenizer.json (revision \(SearchModelSpec.pinned.revision)); the goldens only apply to that file.")
            return
        }
        let tokenizer = try GemmaTokenizer(tokenizerJSON: url)
        let goldens = try Self.goldens()
        #expect(goldens.count > 400)
        var mismatches: [String] = []
        for g in goldens {
            let result = tokenizer.encode(g.text, maxTokens: 512)
            if result.ids != g.ids || tokenizer.encodeBody(g.text).count != g.fullCount { mismatches.append(g.tag) }
        }
        #expect(mismatches.isEmpty, "mismatches in: \(Set(mismatches))")
    }

    static func pinnedTokenizerURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["VAUTA_SEARCH_TOKENIZER"] { return URL(fileURLWithPath: p) }
        if let d = env["VAUTA_SEARCH_MODEL_DIR"] { return URL(fileURLWithPath: d).appendingPathComponent("tokenizer.json") }
        return nil
    }

    struct Golden { let tag: String; let text: String; let ids: [Int32]; let fullCount: Int }

    static func goldens() throws -> [Golden] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SearchModel/tokenizer_goldens.jsonl")
        let data = try Data(contentsOf: url)
        return try data.split(separator: 0x0A).map { line in
            let json = try ByteJSON.parse(Data(line))
            return Golden(tag: json.get("tag")?.string ?? "", text: json.get("text")?.string ?? "",
                          ids: (json.get("ids")?.array ?? []).compactMap { $0.int }.map { Int32($0) }, fullCount: json.get("n")?.int ?? -1)
        }
    }
}

@Suite("Search model: byte-exact JSON and safetensors headers")
struct SearchModelParsingTests {
    @Test func parsesValuesAndKeepsStringsAsBytes() throws {
        let v = try ByteJSON.parse(Data(#"{"a":[1,2.5,"x\u00e9\n"],"b":{"c":true,"d":null},"e":"\ud83d\ude00"}"#.utf8))
        #expect(v.get("a")?.array?.count == 3 && v.get("a")?.array?[0].int == 1 && v.get("a")?.array?[2].string == "xé\n")
        #expect(v.get("e")?.string == "😀")
        // Two keys equal as Strings but different as bytes are two keys.
        let w = try ByteJSON.parse(Data("{\"\u{e9}\":1,\"e\u{301}\":2}".utf8))
        guard case .obj(let items) = w else { Issue.record("not an object"); return }
        #expect(items.count == 2 && w.get("\u{e9}")?.int == 1 && w.get("e\u{301}")?.int == 2)
    }

    @Test func rejectsMalformedInputWithoutCrashing() {
        for bad in ["", "{", "{\"a\"", "{\"a\":", "[1,", "\"abc", "\"\\u12\"", "\"\\ud800\\u0041\"", "{\"a\":1}x", "nul", "{1:2}", "[1 2]"] {
            #expect(throws: ByteJSONError.self) { try ByteJSON.parse(Data(bad.utf8)) }
        }
        #expect(throws: ByteJSONError.tooDeep) { try ByteJSON.parse(Data(String(repeating: "[", count: 200).utf8)) }
    }

    private func file(_ header: String, tail: Int = 16) -> Data {
        var h = Data(header.utf8)
        var out = Data()
        var n = UInt64(h.count).littleEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(h)
        out.append(Data(count: tail))
        h = Data()
        return out
    }

    @Test func parsesAValidHeader() throws {
        let data = file(#"{"__metadata__":{"format":"pt"},"w":{"dtype":"BF16","shape":[2,4],"data_offsets":[0,16]}}"#)
        let entries = try SafetensorsFile.parseHeader(data)
        #expect(entries["w"]?.shape == [2, 4] && entries["w"]?.end == entries["w"]!.start + 16 && entries.count == 1)
    }

    @Test func rejectsEveryKindOfBadHeader() {
        let cases: [String: String] = [
            "offsets past the end": #"{"w":{"dtype":"F16","shape":[1],"data_offsets":[0,9999]}}"#,
            "end before start": #"{"w":{"dtype":"F16","shape":[1],"data_offsets":[8,2]}}"#,
            "negative": #"{"w":{"dtype":"F16","shape":[1],"data_offsets":[-1,2]}}"#,
            "missing dtype": #"{"w":{"shape":[1],"data_offsets":[0,2]}}"#,
            "fractional": #"{"w":{"dtype":"F16","shape":[1],"data_offsets":[0,1.5]}}"#,
            "negative dimension": #"{"w":{"dtype":"F16","shape":[-1],"data_offsets":[0,2]}}"#,
            "not an object": "[1]",
            "garbage": "{{{{",
            "duplicate": #"{"w":{"dtype":"F16","shape":[1],"data_offsets":[0,2]},"w":{"dtype":"F16","shape":[1],"data_offsets":[0,2]}}"#,
        ]
        for (name, header) in cases {
            #expect(throws: SafetensorsError.self, "\(name)") { try SafetensorsFile.parseHeader(file(header)) }
        }
        #expect(throws: SafetensorsError.tooSmall) { try SafetensorsFile.parseHeader(Data(count: 4)) }
        var huge = Data()
        var n = UInt64.max.littleEndian
        withUnsafeBytes(of: &n) { huge.append(contentsOf: $0) }
        huge.append(Data(count: 32))
        #expect(throws: SafetensorsError.headerTooLarge) { try SafetensorsFile.parseHeader(huge) }
        var beyond = Data()
        var m = UInt64(1000).littleEndian
        withUnsafeBytes(of: &m) { beyond.append(contentsOf: $0) }
        beyond.append(Data(count: 32))
        #expect(throws: SafetensorsError.headerOutOfRange) { try SafetensorsFile.parseHeader(beyond) }
    }

    @Test func aThousandMutatedHeadersNeverCrash() {
        let base = Array(#"{"__metadata__":{"format":"pt"},"w":{"dtype":"BF16","shape":[2,4],"data_offsets":[0,16]},"x":{"dtype":"F32","shape":[1],"data_offsets":[16,20]}}"#.utf8)
        var rng = SystemRandomNumberGenerator()
        var accepted = 0
        for _ in 0..<1000 {
            var bytes = base
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let i = Int.random(in: 0..<bytes.count, using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: bytes[i] = UInt8.random(in: 0...255, using: &rng)
                case 1: bytes.remove(at: i)
                default: bytes.insert(UInt8.random(in: 0...255, using: &rng), at: i)
                }
            }
            var data = Data()
            var n = UInt64(bytes.count).littleEndian
            withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
            data.append(contentsOf: bytes)
            data.append(Data(count: 64))
            if (try? SafetensorsFile.parseHeader(data)) != nil { accepted += 1 }
        }
        #expect(accepted < 1000)
    }
}

@Suite("Search model: safetensors overflow")
struct SearchModelSafetensorsOverflowTests {
    @Test func aCraftedShapeThatOverflowsIsRefusedNotTrapped() throws {
        let header = #"{"w":{"dtype":"BF16","shape":[3000000000,3000000000],"data_offsets":[0,16]},"v":{"dtype":"BF16","shape":[3000000000,3000000000],"data_offsets":[0,16]}}"#
        var data = Data()
        var n = UInt64(header.utf8.count).littleEndian
        withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
        data.append(Data(header.utf8))
        data.append(Data(count: 16))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-overflow-\(UUID().uuidString).safetensors")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try SafetensorsFile(url: url)
        #expect(throws: SafetensorsError.shapeMismatch("w")) { try file.gatherRowsBF16("w", ids: [0]) }
        #expect(throws: SafetensorsError.shapeMismatch("v")) { try file.gatherRowsBF16("v", ids: [0]) }
    }
}
