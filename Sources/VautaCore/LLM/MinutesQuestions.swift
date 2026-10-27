// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The parts of the minutes' open questions that can be switched on or off, so the evaluation can regenerate a meeting's minutes with the
/// open questions as they shipped and with the checked ones (`llm-eval --open-questions old|new`). `shipped` is the checked list as a whole;
/// which backend runs it in the app is `MinutesQuestionsRelease.questions(integrated:)`.
public struct MinutesQuestions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// A text of under 4 words, or with no question form and no "whether" cue, is not an open question.
    public static let form = MinutesQuestions(rawValue: 1)
    /// A line of the transcript copied as it is (over 0.8 of its words in one line) is not an open question.
    public static let copy = MinutesQuestions(rawValue: 2)
    /// A question that only restates a topic of the minutes.
    public static let topic = MinutesQuestions(rawValue: 4)
    /// A question a decision or a task of the minutes settles (most of its content words are in that item's text).
    public static let settled = MinutesQuestions(rawValue: 8)
    /// A question that repeats an earlier one.
    public static let repeats = MinutesQuestions(rawValue: 16)
    /// A stock question that fits any meeting ("What are the next steps for…", "What are the implications of…") and says nothing the
    /// transcript holds.
    public static let generic = MinutesQuestions(rawValue: 32)
    /// Apple's model: the list keeps three.
    public static let cap = MinutesQuestions(rawValue: 64)
    /// Apple's model: the digest of a long meeting asks for open questions only from the blocks' "Open" lines.
    public static let digest = MinutesQuestions(rawValue: 128)
    /// Apple's model: the "Open" lines of the digest carry the open questions the block extracts wrote as objects (`{"text", "seg", "quote"}`,
    /// four in five of them), which the digest used to skip. The model is still free to write its own.
    public static let lines = MinutesQuestions(rawValue: 256)

    /// With `form`: a two or three word text still counts when it is asked as a question (a question mark and a question word) and its other
    /// words are said in the transcript ("Who pays?"). Not in `shipped`: the sealed test did not judge it, so it waits for a DEV check and a decision.
    public static let short = MinutesQuestions(rawValue: 512)

    /// Swift drops what is not an open question (`OpenQuestionChecks`).
    public static let checks: MinutesQuestions = [.form, .copy, .topic, .settled, .repeats, .generic]
    /// The checked list (what `--open-questions new` regenerates): the checks and the block questions in the digest. `cap` and `digest` stay out:
    /// on the development meetings each halved the list and the recall of gold open questions along with it (a trade-off to decide).
    public static let shipped: MinutesQuestions = [.form, .copy, .topic, .settled, .repeats, .generic, .lines]
    /// The open questions as the app shipped them before this phase.
    public static let legacy: MinutesQuestions = []

    /// "old" / "legacy", "new" / "shipped", or a comma list of `form`, `copy`, `topic`, `settled`, `repeats`, `generic`, `cap`, `digest`, `lines`, `short`, `checks`.
    public static func parse(_ text: String) -> MinutesQuestions? {
        switch text.lowercased() {
        case "old", "legacy", "none": return .legacy
        case "new", "shipped", "all": return .shipped
        default:
            var out: MinutesQuestions = []
            for word in text.lowercased().split(separator: ",") {
                switch word {
                case "new", "shipped": out.formUnion(.shipped)
                case "old", "legacy": break
                case "checks": out.formUnion(.checks)
                case "form": out.insert(.form)
                case "copy": out.insert(.copy)
                case "topic": out.insert(.topic)
                case "settled": out.insert(.settled)
                case "repeats": out.insert(.repeats)
                case "generic": out.insert(.generic)
                case "cap": out.insert(.cap)
                case "digest": out.insert(.digest)
                case "lines": out.insert(.lines)
                case "short": out.insert(.short)
                default: return nil
                }
            }
            return out
        }
    }

    /// For the traces: "form+copy+…", or "legacy".
    public var names: String {
        let all: [(MinutesQuestions, String)] = [(.form, "form"), (.copy, "copy"), (.topic, "topic"), (.settled, "settled"), (.repeats, "repeats"),
                                                 (.generic, "generic"), (.cap, "cap"), (.digest, "digest"), (.lines, "lines"), (.short, "short")]
        let parts = all.filter { contains($0.0) }.map(\.1)
        return parts.isEmpty ? "legacy" : parts.joined(separator: "+")
    }
}

/// Which open questions the app writes, by backend. The blind comparison on the sealed test meetings: Apple's model lists far fewer
/// non-questions at the same recall, so it runs the checked list; the integrated model showed no difference and keeps the list it had.
public enum MinutesQuestionsRelease {
    public static func questions(integrated: Bool) -> MinutesQuestions { integrated ? .legacy : .shipped }
}
