// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Expanding the user's shorthand notes: the prompt and the reading of the answer. The note is the user's text
/// (material, never instructions); every sentence the model returns has to cite segments that were sent and copy a
/// verbatim quote from one of them (`NoteExpansionVerifier`).
extension VautaPrompts {
    /// A note as one defanged line: it cannot open or close a delimiter, and it cannot start a line with `[S…]`.
    static func noteLine(_ text: String, limit: Int = 600) -> String {
        "- " + PromptText.defang(PromptText.clip(SingleLineText.flatten(text), limit))
    }

    /// The instruction for one note (`notes.count == 1`) or for a few consecutive ones. `earlier` are the notes the user
    /// took just before (context for shorthand such as "same for Q3"; never expanded).
    public static func noteInstruction(_ notes: [String], earlier: [String] = [], maxSentences: Int,
                                       language: OutputLanguage, harness: NoteHarness = .legacy) -> ChatMessage {
        var text = ""
        if !earlier.isEmpty {
            text += "Earlier notes by the user, for context only (do not expand them):\n"
                + earlier.suffix(2).map { noteLine($0, limit: 300) }.joined(separator: "\n") + "\n"
        }
        // With `.prompt` (the small window): the quote is 4 to 15 words (the rule of the minutes and of Ask), a sentence is short, and the
        // shapes are empty, so there is no "…" for the model to copy and no long line to quote.
        let tight = harness.contains(.prompt)
        let quoteRule = tight
            ? "The \"quote\" is a phrase of 4 to 15 words copied word for word from ONE cited segment, exactly as written there (do not join two segments or correct the wording). Each sentence has at most 25 words."
            : "Every sentence cites the segments that support it and copies a verbatim quote from one of them."
        let rules = """
            Write each note out as complete sentences using ONLY what the transcript says about it: who said what, \
            numbers, dates, what was decided or left open. Keep the user's meaning; never contradict or replace it. If \
            the transcript says something different from the note, write what the transcript says as its own sentence \
            with "differs": true. 1 to \(maxSentences) short sentences per note. \(tight ? "Every sentence cites the segments that support it (\"seg\" holds segment numbers only: 10, not S10). " : "")\(quoteRule)
            """
        if notes.count == 1 {
            text += """
                The user typed this short note about the meeting (their words; they may be abbreviated):
                <<<NOTE
                \(noteLine(notes[0]))
                >>>
                \(rules)
                \(tight ? """
                Shape: {"sentences": [{"text": "", "seg": [123], "quote": "", "differs": false}]}. If the transcript does not discuss the note, return {"sentences": []}.
                """ : """
                JSON: {"sentences": [{"text": "…", "seg": [123, 124], "quote": "words copied verbatim from one cited segment", "differs": false}]}. If the transcript does not discuss the note, return {"sentences": []}.
                """)
                """
        } else {
            text += "The user typed these short notes about the meeting (their words; they may be abbreviated):\n"
            for (i, note) in notes.enumerated() {
                text += "<<<NOTE \(i + 1)\n\(noteLine(note))\n>>>\n"
            }
            text += """
                \(rules)
                JSON: {"notes": [{"n": 1, "sentences": [{"text": "…", "seg": [123], "quote": "words copied verbatim from \
                one cited segment", "differs": false}]}]}. A note the transcript does not discuss gets "sentences": [].
                """
        }
        text += "\n\(languageRule(language))"
        return .user(text)
    }

    /// Asks again for the JSON after an answer that could not be read.
    public static func repairNotesInstruction() -> ChatMessage {
        .user("Your answer is not a valid JSON object. Repeat ONLY the JSON of the notes.")
    }

    /// What the model wrote, English keys or the legacy Spanish ones.
    struct RawNoteExpansion: Decodable {
        struct Sentence: Decodable {
            let text: String?, quote: String?, seg: [Int64], differs: Bool
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                text = c.text("text", "texto")
                quote = c.text("quote", "cita")
                seg = c.ids("seg", "segments", "citations", "citas")
                differs = c.value(Bool.self, "differs", "difiere") ?? false
            }
        }
        struct Entry: Decodable {
            let n: Int64?
            let sentences: [Sentence]
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                n = c.id("n", "note")
                sentences = c.list(Sentence.self, "sentences", "oraciones", "frases") ?? []
            }
        }
        let sentences: [Sentence]
        let entries: [Entry]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            sentences = c.list(Sentence.self, "sentences", "oraciones", "frases") ?? []
            entries = c.list(Entry.self, "notes", "notas") ?? []
        }
    }

    /// Everything the checks of an expansion need.
    public struct NoteCheck: Sendable {
        /// The segments the model was shown: a citation outside this set is dropped.
        public var sent: [Int64: CitableSegment]
        public var people: [CandidateEntity]
        public var selfEntity: Int64?
        public var directory: SpeakerDirectory
        public var maxSentences: Int
        /// `NoteHarness.repair`: the text of a sentence loses a trailing "differs: true".
        public var tidy = false

        public init(sent: [Int64: CitableSegment], people: [CandidateEntity] = [], selfEntity: Int64? = nil,
                    directory: SpeakerDirectory = .empty, maxSentences: Int = 3, tidy: Bool = false) {
            self.sent = sent; self.people = people; self.selfEntity = selfEntity; self.directory = directory
            self.maxSentences = maxSentences; self.tidy = tidy
        }
    }

    /// The verified sentences of one note's answer (empty = the transcript does not discuss it). Throws
    /// `LLMError.invalidResponse` when the answer is not a JSON object.
    public static func validateNoteExpansion(_ content: String, check: NoteCheck) throws -> [NoteExpansion.Sentence] {
        let raw = try ModelOutput.decodeObject(RawNoteExpansion.self, from: content)
        return NoteExpansionVerifier.verify(raw.sentences.isEmpty ? (raw.entries.first?.sentences ?? []) : raw.sentences, check: check)
    }

    /// The same for `count` notes asked in one request: one list per note, in order (an absent note gets none).
    public static func validateNoteBatch(_ content: String, count: Int, check: NoteCheck) throws -> [[NoteExpansion.Sentence]] {
        let raw = try ModelOutput.decodeObject(RawNoteExpansion.self, from: content)
        var out = Array(repeating: [NoteExpansion.Sentence](), count: count)
        for (i, entry) in raw.entries.enumerated() {
            // A model-supplied number is never trusted to be in range (Int64.min would overflow the subtraction).
            let index = entry.n.map { n in Int(exactly: n).flatMap { $0 >= 1 ? $0 - 1 : nil } ?? -1 } ?? i
            guard out.indices.contains(index) else { continue }
            out[index] = NoteExpansionVerifier.verify(entry.sentences, check: check)
        }
        if raw.entries.isEmpty, count == 1 { out[0] = NoteExpansionVerifier.verify(raw.sentences, check: check) }
        return out
    }
}
