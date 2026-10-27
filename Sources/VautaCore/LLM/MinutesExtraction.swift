// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The parts of the extraction of decisions and tasks that can be switched on or off, so the evaluation can regenerate the minutes of a
/// meeting with the old extraction and the new one (`llm-eval --extraction old|new`). `shipped` is the new extraction as a whole; which backends
/// run it in the app is `MinutesRelease.extraction(integrated:)`.
public struct MinutesExtraction: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The definitions with exclusions, "Me" only when the transcript has Me lines, small caps per block (Apple), owners named only
    /// when the words say so (integrated model).
    public static let prompts = MinutesExtraction(rawValue: 1)
    /// The filter that drops what is not a task or decision and marks what lacks a commitment or an agreement `unconfirmed`.
    public static let evidence = MinutesExtraction(rawValue: 2)
    /// The owner from the clause and the lines around it, never from the model's label.
    public static let owners = MinutesExtraction(rawValue: 4)
    /// One more request over the last stretch of the meeting, so the closing tasks are not lost.
    public static let closing = MinutesExtraction(rawValue: 8)
    /// A due day is kept only when the words around it back it.
    public static let dueEvidence = MinutesExtraction(rawValue: 16)
    /// Evaluation only: items without a cue are dropped instead of being marked "to be confirmed" (option (b) of the design).
    public static let dropUnconfirmed = MinutesExtraction(rawValue: 32)
    /// Evaluation only: the diagnostics' counts also carry one key per item with its verdict (segment, start of the text, reason). Public
    /// transcripts only; the app cannot set it (`LLMService.setMinutesExtraction` is internal).
    public static let explain = MinutesExtraction(rawValue: 64)
    /// Evaluation only: the block extracts of a long meeting do not ask for at most 3 decisions and 3 tasks.
    public static let uncapped = MinutesExtraction(rawValue: 128)
    /// The definitions with exclusions (and the cap, unless `uncapped`) in the block extracts of a long meeting, the map step of Apple's
    /// model. Separate from `prompts` because the development meetings showed it lowers the recall of Apple's model without making its items
    /// better; kept switchable for the evaluation.
    public static let blockPrompts = MinutesExtraction(rawValue: 256)

    /// Meeting-level consolidation and ranking after the checks (`MinutesRanking`): repeats across blocks collapse, a proposal the meeting
    /// restated later goes, and only the best items of the meeting stay firm; the rest are "to be confirmed". For Apple's model (the
    /// integrated model's list is already short, so it is not ranked).
    public static let ranking = MinutesExtraction(rawValue: 512)
    /// The block extracts of a long meeting leave out `entities` when the meeting offers no person or project to link (the proposals
    /// would all be dropped as unknown).
    public static let blockShape = MinutesExtraction(rawValue: 1024)
    /// Evaluation only, and off: the development replay of 2026-10-24 lost a real firm decision in one of three passes, so it does not ship. An item about running the meeting ("go to the next slide", the agenda, a break, who speaks next) is
    /// never firm, whatever its rank; it goes to "to be confirmed" with the reason `rank` (or `rank:<code>` when a soft check had doubted it) and does not take one of the firm places.
    public static let procedureNeverFirm = MinutesExtraction(rawValue: 2048)

    /// The new extraction, every part (what `--extraction new` regenerates). The integrated model runs this set and Apple's model a superset of it (`ranked`): see `MinutesRelease`.
    public static let shipped: MinutesExtraction = [.prompts, .evidence, .owners, .closing, .dueEvidence]
    /// The new extraction with the ranking and the lean block shape: what `--extraction new` regenerates for Apple's model. Apple's model runs it in the app
    /// (`MinutesRelease.extraction(integrated:)`).
    public static let ranked: MinutesExtraction = shipped.union([.ranking, .blockShape])
    /// The extraction before this phase.
    public static let legacy: MinutesExtraction = []

    /// "old" / "legacy", "new" / "shipped", or a comma list of `prompts`, `evidence`, `owners`, `closing`, `due`, `drop`, `rank`, `shape`, `procedure`.
    public static func parse(_ text: String) -> MinutesExtraction? {
        switch text.lowercased() {
        case "old", "legacy", "none": return .legacy
        case "new", "shipped", "all": return .ranked
        case "integrated": return .shipped
        default:
            var out: MinutesExtraction = []
            for word in text.lowercased().split(separator: ",") {
                switch word {
                case "new", "shipped": out.formUnion(.ranked)
                case "integrated": out.formUnion(.shipped)
                case "rank", "ranking": out.insert(.ranking)
                case "shape": out.insert(.blockShape)
                case "procedure": out.insert(.procedureNeverFirm)
                case "old", "legacy": break
                case "prompts": out.insert(.prompts)
                case "evidence": out.insert(.evidence)
                case "owners": out.insert(.owners)
                case "closing": out.insert(.closing)
                case "due": out.insert(.dueEvidence)
                case "drop": out.insert(.dropUnconfirmed)
                case "explain": out.insert(.explain)
                case "uncapped": out.insert(.uncapped)
                case "blocks": out.insert(.blockPrompts)
                default: return nil
                }
            }
            return out
        }
    }

    /// For the traces: "prompts+evidence+owners+closing+due", or "legacy".
    public var names: String {
        let parts = [contains(.prompts) ? "prompts" : nil, contains(.evidence) ? "evidence" : nil, contains(.owners) ? "owners" : nil,
                     contains(.closing) ? "closing" : nil, contains(.dueEvidence) ? "due" : nil, contains(.dropUnconfirmed) ? "drop" : nil, contains(.explain) ? "explain" : nil, contains(.uncapped) ? "uncapped" : nil, contains(.blockPrompts) ? "blocks" : nil,
                     contains(.ranking) ? "ranking" : nil, contains(.blockShape) ? "shape" : nil, contains(.procedureNeverFirm) ? "procedure" : nil].compactMap { $0 }
        return parts.isEmpty ? "legacy" : parts.joined(separator: "+")
    }
}

/// Which extraction the app runs, by backend. Decided on 2026-10-20: the integrated model runs the new extraction (`.shipped`).
/// Harness phase: Apple's on-device model runs the ranked one (`.ranked`) after the blind comparison; the model servers keep the old one
/// (`.legacy`), as they were not measured. The evidence (docs/LANGUAGE_MODEL.md has the tables): the citation-verification rate on the 15 test meetings
/// did not drop detectably for either backend (Apple 0.571 to 0.611, integrated 0.921 to 0.912; non-inferiority within 0.05 is not shown
/// at this sample size). In the blind pairwise comparison the integrated model's summary errors were 6 old and 7 new (no detectable
/// difference). Apple's earlier phase was unfavourable (summary errors 18 old and 23 new, invented or wrong items 10 to 16), which is
/// why it kept the old extraction then; the harness phase's blind test on 20 sealed meetings turned that round (firm list 518 to 185 items, proposals
/// stated as firm 50 to 20, invented items 7 to 2, firm recall 99 to 100 of 167). The servers were not measured.
public enum MinutesRelease {
    public static func extraction(integrated: Bool) -> MinutesExtraction { ranked(integrated: integrated) ? .ranked : integrated ? .shipped : .legacy }

    /// Whether the backend runs the new extraction with the ranking (`MinutesExtraction.ranked`). On for Apple's model after the blind
    /// judgement of the ranked list against the old one (equal recall, a list 64% shorter, fewer proposals stated as firm); the integrated
    /// model never ranks (`MinutesRanking` applies to Apple's list).
    public static func ranked(integrated: Bool) -> Bool { !integrated }
}
