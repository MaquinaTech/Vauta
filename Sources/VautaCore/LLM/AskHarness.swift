// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The parts of Ask's request and retrieval that can be switched on or off, so the evaluation can ask the same questions with Ask as it shipped
/// and with the harness of this phase (`llm-eval --ask old|new`). `shipped` is the whole harness; which backend runs it in the app is
/// `AskHarnessRelease.harness(integrated:)`. Every part is deterministic: no model call is added.
public struct AskHarness: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Apple's model (the small window): the rule that a proposal is not a decision is sent only with a question about a decision, a vote or
    /// an agreement (`isDecisionQuestion`); any other question gets a plain "answer with the facts" rule. Against a model that wrote
    /// "was proposed or sent on" into the answers to questions of fact.
    public static let factRule = AskHarness(rawValue: 1)
    /// Apple's model (the small window): five short windows centred on the keyword hits instead of three passages of a hundred seconds,
    /// spelled numbers and digits (English, Spanish) in the keyword query, and a rerank by the share of the question's words a window holds.
    public static let windows = AskHarness(rawValue: 2)
    /// Both backends: the passages are sent oldest first and each one is labelled with its meeting's place among the meetings sent
    /// ("Meeting 2 of 3, oldest first"), so a question about the first or the last meeting has something to count on.
    public static let order = AskHarness(rawValue: 4)
    /// Evaluation only: the keyword query is translated into the transcripts' language as the app does it (the translator is installed
    /// on the Mac, `LLMService.setQueryTranslation`). The app always has it; `llm-eval` had never set it.
    public static let queryTranslation = AskHarness(rawValue: 8)

    /// Every part (what `--ask new` runs). The app does not: see `AskHarnessRelease`.
    public static let shipped: AskHarness = [.factRule, .windows, .order, .queryTranslation]
    /// Ask as it shipped before this item.
    public static let legacy: AskHarness = []

    /// "old" / "legacy", "new" / "shipped", or a comma list of `rule`, `windows`, `order`, `translate`.
    public static func parse(_ text: String) -> AskHarness? {
        switch text.lowercased() {
        case "old", "legacy", "none": return .legacy
        case "new", "shipped", "all": return .shipped
        default:
            var out: AskHarness = []
            for word in text.lowercased().split(separator: ",") {
                switch word {
                case "new", "shipped": out.formUnion(.shipped)
                case "old", "legacy": break
                case "rule", "fact": out.insert(.factRule)
                case "windows": out.insert(.windows)
                case "order": out.insert(.order)
                case "translate": out.insert(.queryTranslation)
                default: return nil
                }
            }
            return out
        }
    }

    /// For the traces.
    public var names: String {
        let parts = [contains(.factRule) ? "rule" : nil, contains(.windows) ? "windows" : nil, contains(.order) ? "order" : nil,
                     contains(.queryTranslation) ? "translate" : nil].compactMap { $0 }
        return parts.isEmpty ? "legacy" : parts.joined(separator: "+")
    }
}

/// Which harness the app runs, by backend. Until a blind comparison on the sealed test meetings says otherwise, every backend keeps the
/// Ask it had.
public enum AskHarnessRelease {
    public static func harness(integrated: Bool) -> AskHarness { .legacy }
}

extension LLMService {
    /// The harness an Ask request runs: the evaluation's choice, else the release choice for the backends the phase measured. A model server keeps
    /// the Ask it had, whatever the release says (`release` is for the tests).
    func askHarness(for chat: ChatProvider, release: AskHarness? = nil) -> AskHarness {
        askHarnessOverride ?? (chat.releasedHarness ? release ?? AskHarnessRelease.harness(integrated: chat.integrated) : .legacy)
    }
}

// MARK: The question's kind

extension AskHarness {
    /// Stems that say a question is about a decision, a vote or an agreement (English and Spanish). Compared with the start of each word
    /// of the question, accents and case ignored.
    private static let decisionStems = [
        "decid", "decision", "agree", "agreed", "agreement", "approv", "vote", "voted", "voting", "settle", "resolv", "resolution", "conclu", "choos", "chose",
        "chosen", "adopt", "verdict", "ruling", "greenlight", "sign off", "signed off", "go ahead", "go with", "went with",
        "acord", "acuerd", "aprob", "voto", "voti", "vota", "resolu", "elig", "eleg", "adopt", "quedo en", "se fijo", "se acepto"
    ]

    /// Whether the question asks about a decision, a vote or an agreement: the only questions that need the rule that a proposal is not a
    /// decision. A deterministic cue on the words of the question; a miss only costs the caution, never the answer.
    public static func isDecisionQuestion(_ question: String) -> Bool {
        let text = " " + TextKeys.norm(question) + " "
        return decisionStems.contains { stem in
            // A stem starts a word; a phrase ("go with") is found as written.
            text.contains(" " + stem)
        }
    }
}

// MARK: Numbers in the keyword query

extension AskHarness {
    private static let numberWords: [(value: Int, english: String, spanish: String)] = [
        (0, "zero", "cero"), (1, "one", "uno"), (2, "two", "dos"), (3, "three", "tres"), (4, "four", "cuatro"), (5, "five", "cinco"),
        (6, "six", "seis"), (7, "seven", "siete"), (8, "eight", "ocho"), (9, "nine", "nueve"), (10, "ten", "diez"), (11, "eleven", "once"),
        (12, "twelve", "doce"), (13, "thirteen", "trece"), (14, "fourteen", "catorce"), (15, "fifteen", "quince"), (16, "sixteen", "dieciseis"),
        (17, "seventeen", "diecisiete"), (18, "eighteen", "dieciocho"), (19, "nineteen", "diecinueve"), (20, "twenty", "veinte"),
        (30, "thirty", "treinta"), (40, "forty", "cuarenta"), (50, "fifty", "cincuenta"), (60, "sixty", "sesenta"), (70, "seventy", "setenta"),
        (80, "eighty", "ochenta"), (90, "ninety", "noventa"), (100, "hundred", "cien")
    ]
    private static let wordToValue: [String: Int] = {
        var out: [String: Int] = [:]
        for entry in numberWords { out[entry.english] = entry.value; out[entry.spanish] = entry.value }
        out["ciento"] = 100
        return out
    }()
    private static let valueToWords: [Int: [String]] = {
        var out: [Int: [String]] = [:]
        for entry in numberWords { out[entry.value] = [entry.english, entry.spanish] }
        return out
    }()

    /// The other ways a keyword term may be written in a transcript: "12.50" is "twelve fifty" or "twelve and a half" ("doce y medio"), "twelve"
    /// is "12". Only whole numbers up to 100 and decimals whose parts are such numbers; empty for any other term. The spoken forms of a
    /// number are separate words, so each part is one variant.
    public static func numberVariants(of term: String) -> [String] {
        let raw = term.trimmingCharacters(in: .whitespaces).lowercased()
        let norm = TextKeys.norm(raw)
        if let value = wordToValue[norm] { return [String(value)] }
        let parts = raw.split(whereSeparator: { $0 == "." || $0 == "," }).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return [] }
        var out: [String] = []
        func add(_ number: String) {
            guard let value = Int(number) else { return }
            if value < 21 || (value <= 100 && value % 10 == 0) { out.append(contentsOf: valueToWords[value] ?? []) }
        }
        add(parts[0])
        if parts.count == 2 {
            let fraction = parts[1]
            out.append(fraction)
            add(fraction)
            // Half: 12.5, 12.50.
            if Int(fraction) == 5 || Int(fraction) == 50 { out.append(contentsOf: ["half", "medio", "media"]) }
        }
        var seen = Set<String>()
        return out.filter { $0 != raw && seen.insert($0).inserted }
    }

    /// The question's keyword terms, each with the other spellings of the numbers among them. A group is one idea: a window holds the idea
    /// when it holds any of the group's words.
    public static func termGroups(_ terms: [String]) -> [[String]] {
        terms.map { [$0] + numberVariants(of: $0) }
    }
}

// MARK: Windows

/// The shape of Ask's short windows on the small window (`AskHarness.windows`).
public struct AskWindows: Sendable, Equatable {
    /// Seconds kept before and after a keyword hit. The answer follows the line that names its subject more often than it precedes it.
    public var before = 20.0, after = 40.0
    /// A window never holds more than this many characters of text (its lines furthest from the hit go first).
    public var maxCharacters = 1_100
    /// How many windows are candidates: the best hits of the keyword search.
    public var candidates = 40
    /// How much the share of the question's words a window holds weighs against the rank of its hits (0 = rank alone). Tuned on the
    /// development meetings: 0 sent a gold line 0.72 of the time, 2 0.78, 16 0.83; more changed nothing.
    public var coverageWeight = 16.0
    /// Windows sent.
    public var count = 5
    public init() {}
    public static let standard = AskWindows()

    /// `before=20,after=30,chars=1100,count=5,coverage=2,candidates=40` (evaluation: tuning on the development meetings).
    public static func parse(_ text: String) -> AskWindows? {
        var out = AskWindows()
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=")
            guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            switch parts[0] {
            case "before": out.before = value
            case "after": out.after = value
            case "chars": out.maxCharacters = Int(value)
            case "count": out.count = Int(value)
            case "coverage": out.coverageWeight = value
            case "candidates": out.candidates = Int(value)
            default: return nil
            }
        }
        return out
    }

    /// Final score of a window: the hits it holds (each 1 / (60 + rank)) raised by how many of the question's ideas it holds.
    public func score(hits: Double, coverage: Double) -> Double { hits * (1 + coverageWeight * coverage) }
}
