// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What Gemma's own tokens can write under the grammars, on the REAL 262k-token vocabulary (needs the installed model's tokenizer,
/// `VAUTA_LLM_MODEL_DIR`, not its weights). These are the checks behind the 11a.1 finding: the compact grammar offered no way to write
/// the whitespace Gemma puts before `]` and `}`, so the junk went into strings.
@Suite("Language model: JSON the real tokens can write", .serialized)
struct LanguageModelRealJSONTests {
    static let enabled = ProcessInfo.processInfo.environment["VAUTA_LLM_MODEL_DIR"] != nil
    static let offered = OutputSchemas.Offered(segments: Set(1...400), entities: Set(1...12), documents: Set(1...6))

    /// Writes `text` the way the model would, one token at a time in the tokenizer's own segmentation of what is left, and returns the
    /// byte at which the grammar refused (nil = all of it was writable). Forced stretches are taken as written by the constraint.
    static func firstRefusal(_ text: String, schema: OutputSchema, tokenizer: GemmaTokenizer, whitespace: Bool) -> Int? {
        let constraint = SchemaConstraint(schema: schema, tokenizer: tokenizer, whitespace: whitespace)
        let bytes = Array(text.utf8)
        var pos = 0
        while pos < bytes.count {
            let rest = String(decoding: bytes[pos...], as: UTF8.self)
            switch constraint.nextMask() {
            case .free: return pos
            case .forced(let t):
                let b = tokenizer.tokenBytes(t)
                guard t != SchemaConstraint.stopToken, Array(bytes[pos...].prefix(b.count)) == b else { return pos }
                constraint.accept(t)
                pos += b.count
            case .forcedSequence(let ts):
                for t in ts {
                    let b = tokenizer.tokenBytes(t)
                    guard Array(bytes[pos...].prefix(b.count)) == b else { return pos }
                    constraint.accept(t)
                    pos += b.count
                }
            case .allowed(let bits):
                // Any token whose bytes are the next bytes of the text and that the grammar allows will do; the tokenizer's own first
                // token of what is left is the natural one.
                guard let natural = tokenizer.encodeLiteral(rest).first, bits[Int(natural) >> 6] & (1 << UInt64(natural & 63)) != 0 else { return pos }
                constraint.accept(natural)
                pos += tokenizer.tokenBytes(natural).count
            }
        }
        return nil
    }

    static let layouts: [(name: String, text: String)] = [
        ("compact", #"{"title":"Budget","summary":"We met.","topics":["a","b"],"decisions":[],"tasks":[],"entities":[],"open_questions":[]}"#),
        ("prompt style", "{\"title\": \"Budget\",\n \"summary\": \"We met.\",\n \"topics\": [\"a\", \"b\"],\n \"decisions\": [],\n \"tasks\": [],\n \"entities\": [],\n \"open_questions\": []}"),
        ("closing on its own line", "{\"title\": \"Budget\", \"summary\": \"We met.\", \"topics\": [\"a\"], \"decisions\": [], \"tasks\": [], \"entities\": [], \"open_questions\": []\n}"),
        ("indented", "{\n  \"title\": \"Budget\",\n  \"summary\": \"We met.\",\n  \"topics\": [\n    \"a\",\n    \"b\"\n  ],\n  \"decisions\": [],\n  \"tasks\": [],\n  \"entities\": [],\n  \"open_questions\": [\n  ]\n}"),
        ("items", "{\"title\": \"Budget\", \"summary\": \"We met.\", \"topics\": [\"a\"],\n \"decisions\": [{\"text\": \"Keep it\", \"seg\": 12, \"quote\": \"keep it as is\"}],\n \"tasks\": [{\"text\": \"Send\", \"owner\": null, \"owner_id\": null, \"due\": null, \"seg\": 3, \"quote\": \"send it\"}],\n \"entities\": [],\n \"open_questions\": [\"Who signs?\"]\n}"),
    ]

    @Test(.enabled(if: enabled), .timeLimit(.minutes(20)))
    func everyLayoutOfTheMinutesIsWritableWithWhitespaceAndEmptyArraysToo() async throws {
        let tokenizer = try await LanguageModelEngine(store: LanguageModelSelfTest.store()).loadedTokenizer()
        let schema = OutputSchemas.minutes(Self.offered)
        for layout in Self.layouts {
            let refusal = Self.firstRefusal(layout.text, schema: schema, tokenizer: tokenizer, whitespace: true)
            #expect(refusal == nil, "\(layout.name): refused at byte \(refusal ?? -1) of \(layout.text.utf8.count)")
        }
        // The compact grammar writes the compact layout and nothing with a space in it: that was the defect.
        #expect(Self.firstRefusal(Self.layouts[0].text, schema: schema, tokenizer: tokenizer, whitespace: false) == nil)
        for layout in Self.layouts.dropFirst() {
            #expect(Self.firstRefusal(layout.text, schema: schema, tokenizer: tokenizer, whitespace: false) != nil, "\(layout.name) cannot be written without whitespace")
        }
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(20)))
    func theEmptyListAndTheClosingBraceNeedNoStringToHideIn() async throws {
        let tokenizer = try await LanguageModelEngine(store: LanguageModelSelfTest.store()).loadedTokenizer()
        let schema = OutputSchemas.minutes(Self.offered)
        let upToOpenQuestions = #"{"title":"T","summary":"S","topics":[],"decisions":[],"tasks":[],"entities":[],"open_questions":["#
        func allowedTokens(whitespace: Bool) -> [[UInt8]] {
            let c = SchemaConstraint(schema: schema, tokenizer: tokenizer, whitespace: whitespace)
            for t in tokenizer.encodeLiteral(upToOpenQuestions) { _ = c.nextMask(); c.accept(t) }
            guard case .allowed(let bits) = c.nextMask() else { return [] }
            return (0..<tokenizer.vocabularySize).filter { bits[$0 >> 6] & (1 << UInt64($0 & 63)) != 0 }.map { tokenizer.tokenBytes(Int32($0)) }
        }
        func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
        // With whitespace, `]\n}`, `]` and `]}` are there (and a newline or a space first).
        let open = allowedTokens(whitespace: true).map(text)
        #expect(open.contains("]\n}") || open.contains("]\n\n}") || open.contains("]}"), "a token that closes the list and the object")
        #expect(open.contains("]") && open.contains("\n") && open.contains(" "))
        // Without it, the way out of the list is `]`, `]}` or a string; what the model wants after a pretty-printed `[` (a line break)
        // is not there, while a quote followed by `]` or `}` (the opening of a string that starts with a bracket) is.
        let compact = allowedTokens(whitespace: false).map(text)
        #expect(!compact.contains("\n") && !compact.contains(" ") && !compact.contains("]\n}") && !compact.contains("]\n"))
        #expect(compact.contains { $0.hasPrefix("\"]") || $0.hasPrefix("\"}") }, "the only place left for a closing bracket is inside a string")
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(20)))
    func theAnswerInEveryLayoutIsWritableAndFoundFalseHasNoClaims() async throws {
        let tokenizer = try await LanguageModelEngine(store: LanguageModelSelfTest.store()).loadedTokenizer()
        let schema = OutputSchemas.answer(Self.offered)
        let samples = [
            #"{"found":true,"answer":"It stays.","claims":[{"text":"Kept","citations":[12],"quote":"keep it as is"}]}"#,
            "{\"found\": true,\n \"answer\": \"It stays.\",\n \"claims\": [{\"text\": \"Kept\", \"citations\": [12, 13], \"quote\": \"keep it as is\"}]\n}",
            #"{"found":false,"answer":"Not there.","claims":[]}"#,
            "{\"found\": false,\n \"answer\": \"Not there.\",\n \"claims\": [\n ]\n}",
        ]
        for sample in samples {
            let refusal = Self.firstRefusal(sample, schema: schema, tokenizer: tokenizer, whitespace: true)
            #expect(refusal == nil, "\(sample.debugDescription) refused at byte \(refusal ?? -1)")
        }
        // A quote of 7 bytes is under the grammar's minimum and is refused; one of 8 is not.
        #expect(Self.firstRefusal(#"{"found":true,"answer":"It stays.","claims":[{"text":"Kept","citations":[12],"quote":"keep it"}]}"#, schema: schema, tokenizer: tokenizer, whitespace: true) != nil)
        #expect(Self.firstRefusal(#"{"found":true,"answer":"It stays.","claims":[{"text":"Kept","citations":[12],"quote":"keep it!"}]}"#, schema: schema, tokenizer: tokenizer, whitespace: true) == nil)
        // found=true cannot end its claims empty, found=false cannot start a claim.
        #expect(Self.firstRefusal(#"{"found":true,"answer":"x","claims":[]}"#, schema: schema, tokenizer: tokenizer, whitespace: true) != nil)
        #expect(Self.firstRefusal(#"{"found":false,"answer":"x","claims":[{"text":"a"}]}"#, schema: schema, tokenizer: tokenizer, whitespace: true) != nil)
    }
}
