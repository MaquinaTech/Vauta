// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The parts of the notepad expansion that can be switched on or off, so the evaluation can expand the same notes with the request as it
/// shipped and with the harness of this phase (`llm-eval --notes old|new`). Only the small window (the on-device model, about 4K tokens)
/// is affected: a large window runs the request it always had whatever the switch says. Every part is deterministic: no model call is added.
public struct NoteHarness: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The note prompt asks for a quote of 4 to 15 words and shows empty shapes (no "…" to copy), and the grammar bounds the sentence and
    /// the quote, so a reply is a few short sentences instead of a long copied line that runs out of tokens.
    public static let prompt = NoteHarness(rawValue: 1)
    /// The output limit is what the window leaves after the instruction and the transcript, not 320 tokens.
    public static let budget = NoteHarness(rawValue: 2)
    /// A reply cut at the limit keeps its finished sentences (closed at the last complete element, then verified as any other reply)
    /// instead of failing the note.
    public static let salvage = NoteHarness(rawValue: 4)
    /// Deterministic repair of what the small model writes: the segment tags it copies from the transcript (`"seg": [S10]` is not JSON) become
    /// numbers before the reply is read, and a "differs: true" it writes into a sentence's text is removed from the text.
    public static let repair = NoteHarness(rawValue: 8)
    /// A sentence of a note taken during the meeting stays only if it cites something said within `NoteReply.lookBack` seconds before the note
    /// (or after it): the small model otherwise writes verified sentences about the start of the window.
    public static let relevance = NoteHarness(rawValue: 32)

    /// Every part (what `--notes new` runs). The app does not: see `NoteHarnessRelease`.
    public static let shipped: NoteHarness = [.prompt, .budget, .salvage, .repair, .relevance]
    /// The expansion as it shipped before this item.
    public static let legacy: NoteHarness = []

    /// "old" / "legacy", "new" / "shipped", or a comma list of `prompt`, `budget`, `salvage`, `repair`, `relevance`.
    public static func parse(_ text: String) -> NoteHarness? {
        switch text.lowercased() {
        case "old", "legacy", "none": return .legacy
        case "new", "shipped", "all": return .shipped
        default:
            var out: NoteHarness = []
            for word in text.lowercased().split(separator: ",") {
                switch word {
                case "new", "shipped": out.formUnion(.shipped)
                case "old", "legacy": break
                case "prompt": out.insert(.prompt)
                case "budget": out.insert(.budget)
                case "salvage": out.insert(.salvage)
                case "repair": out.insert(.repair)
                case "relevance": out.insert(.relevance)
                default: return nil
                }
            }
            return out
        }
    }

    /// For the traces.
    public var names: String {
        let parts = [contains(.prompt) ? "prompt" : nil, contains(.budget) ? "budget" : nil, contains(.salvage) ? "salvage" : nil,
                     contains(.repair) ? "repair" : nil,
                     contains(.relevance) ? "relevance" : nil].compactMap { $0 }
        return parts.isEmpty ? "legacy" : parts.joined(separator: "+")
    }
}

/// Which harness the app runs, by backend. Until a blind comparison on the sealed test meetings says otherwise, every backend keeps the
/// expansion it had.
public enum NoteHarnessRelease {
    public static func harness(integrated: Bool) -> NoteHarness { .legacy }
}

extension ContextBudget {
    /// The output limit of one note's request: 320 tokens on the small window as it shipped; with `.budget`, what the window leaves after
    /// the prompt (`promptTokens`, instruction and transcript as sent), at most `ceiling`, never under the old limit. Large windows are unchanged.
    func noteOutputLimit(_ harness: NoteHarness, promptTokens: Int?) -> Int {
        guard isSmall, harness.contains(.budget) else { return noteOutput }
        guard let promptTokens else { return Self.noteOutputCeiling }
        return max(noteOutput, min(Self.noteOutputCeiling, contextTokens - promptTokens - safety))
    }

    /// A note's sentences are short (at most 3 of about 25 words): 700 tokens hold them with the JSON around them.
    static let noteOutputCeiling = 700
}

extension LLMService {
    /// The harness a request of this budget runs: the evaluation's choice, else the release choice for the backend. A large window and a
    /// model server (a backend the phase did not measure) are always `legacy`.
    func noteHarness(for chat: ChatProvider, budget: ContextBudget, release: NoteHarness? = nil) -> NoteHarness {
        guard budget.isSmall else { return .legacy }
        return noteHarnessOverride ?? (chat.releasedHarness ? release ?? NoteHarnessRelease.harness(integrated: chat.integrated) : .legacy)
    }

    /// Evaluation only: forces the notepad harness (`nil` = the release choice).
    func setNoteHarness(_ harness: NoteHarness?) { noteHarnessOverride = harness }
}

/// What the small model writes into a notepad reply, put right before the reply is read.
enum NoteReply {
    /// The text with the `S` of a segment tag removed outside the strings (`[S10, S11]` becomes `[10, 11]`); the strings are untouched.
    static func repaired(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var inString = false, escaped = false
        var previous: Character = " "
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if (ch == "S" || ch == "s"), i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isNumber, !(previous.isLetter || previous.isNumber) {
                i += 1
                previous = ch
                continue
            }
            out.append(ch)
            previous = ch
            i += 1
        }
        return out
    }

    /// A sentence's text without the "differs: true" or "seg: 101" the model sometimes writes at its end (they are keys of their own).
    static func tidied(_ text: String) -> String {
        var out = text
        var changed = false
        while let range = out.range(of: #"\s*[(\[]?\s*(differs|seg|quote)\s*[:=]\s*(true|false|\[?[\d, S]+\]?)\s*[)\]]?\s*\.?\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            out = String(out[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            changed = true
        }
        guard changed else { return text }
        if let last = out.last, ![".", "!", "?", "。"].contains(last) { out += "." }
        return out
    }

    /// Seconds before a note that a sentence may cite. Measured on the development meetings: of the verified sentences, those whose nearest
    /// cited line was said later than this before the note were near the gold lines 41% of the time, the others 78%.
    static let lookBack = 75.0

    /// The sentences of an expansion of `note` worth keeping: for a note taken during the meeting, one that cites a segment said within
    /// `lookBack` seconds before the note, or after it. A note typed after the meeting has no time of its own: all stay.
    static func relevant(_ sentences: [NoteExpansion.Sentence], to note: MeetingNote) -> [NoteExpansion.Sentence] {
        guard !note.addedAfter else { return sentences }
        return sentences.filter { sentence in
            guard let nearest = sentence.cites.map({ $0.t - note.t }).min(by: { abs($0) < abs($1) }) else { return false }
            return nearest >= -lookBack
        }
    }
}
