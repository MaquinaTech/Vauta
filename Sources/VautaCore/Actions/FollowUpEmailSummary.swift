// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The optional summary of the email: the minutes' summary has no citation, so a sentence is kept only when what it says can be found
/// in the transcript. At most three sentences, 600 characters. Off by default, and offered only on backends where the evaluation shows
/// the summary accurate.
public enum FollowUpEmailSummary {
    public static let maximumSentences = 3

    /// The models whose summary sentences were measured against the transcript and passed the email gate. None has been
    /// measured yet, so the toggle is not offered anywhere: a backend is added here only with its evaluation result. Keys are the
    /// backend names the app reports: "onDevice", "integrated", "server".
    public static let measuredAccurateBackends: Set<String> = []

    public static func isOffered(backend: String) -> Bool { measuredAccurateBackends.contains(backend) }
    public static let maximumCharacters = 600

    public static func sentences(of input: FollowUpEmailInput) -> [String] {
        let transcript = input.transcript.joined(separator: "\n")
        guard !transcript.isEmpty else { return [] }
        var out: [String] = []
        var length = 0
        for sentence in split(input.summary) {
            guard out.count < maximumSentences else { break }
            // Every figure must be written in the transcript, and every person named must be backed by it.
            guard MinutesVerifier.figuresAreInSegment(item: sentence, segment: transcript),
                  MinutesVerifier.namedPeopleAreBacked(itemText: sentence, people: input.people, segment: transcript, speakerEntity: nil) else { continue }
            // A sentence that dates something ("today", "last Tuesday", "on 3 March") may date the meeting differently: skipped.
            guard !datesSomething(sentence) else { continue }
            guard length + sentence.count <= maximumCharacters else { break }
            out.append(sentence)
            length += sentence.count
        }
        return out
    }

    /// Sentences, split at . ! ? and their CJK forms.
    static func split(_ summary: String) -> [String] {
        let text = SingleLineText.flatten(summary)
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let cjk = "。！？".contains(ch)
            let latin = ".!?".contains(ch) && (i + 1 == chars.count || chars[i + 1].isWhitespace)
            if cjk || latin {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    private static func datesSomething(_ sentence: String) -> Bool {
        let norm = TextKeys.norm(sentence)
        if !DateWords.mentionedWeekdays(norm).isEmpty || DateWords.mentionsTomorrow(norm) || DateWords.contains(norm, DateWords.today) { return true }
        if DateWords.contains(norm, ["yesterday", "ayer", "hier", "gestern", "ieri", "ontem", "昨日", "昨天", "어제"]) { return true }
        let tokens = norm.split(separator: " ").map(String.init)
        if tokens.contains(where: { FollowUpWords.monthNames[$0] != nil && !["may", "mar", "mars", "set", "sept", "mai"].contains($0) }) { return true }
        return norm.range(of: #"\d{1,2}\s?(月|월)"#, options: .regularExpression) != nil
    }
}

/// A build check: every content line of a draft is a stored field, copied unchanged. Not an accuracy claim about the minutes.
public enum FollowUpEmailTracer {
    /// The lines of `draft` whose stored field is not one of the input's fields, or that do not contain it unchanged, or whose
    /// extra values (an owner's name, a due day) are not stored either. Empty = every line is traceable.
    public static func violations(_ draft: FollowUpEmailDraft, input: FollowUpEmailInput) -> [FollowUpEmailDraft.Line] {
        let decisions = Set(input.decisions.map { SingleLineText.flatten($0.text) })
        let tasks = Dictionary(uniqueKeysWithValues: input.tasks.map { ($0.id, $0) })
        let questions = Set(input.openQuestions.map { SingleLineText.flatten($0) })
        let summary = SingleLineText.flatten(input.summary)
        let names = Set(input.tasks.compactMap(\.ownerName) + draft.ownerName.map { [$0] }.orEmpty)
        let days = Set(input.tasks.compactMap { $0.dueDay?.string })
        return draft.lines.filter { line in
            guard let field = line.field else { return false }
            guard line.text.contains(field) else { return true }
            switch line.kind {
            case .decision: if !decisions.contains(field) { return true }
            case .task:
                guard let id = line.taskID, let task = tasks[id], SingleLineText.flatten(task.text) == field else { return true }
            case .openQuestion: if !questions.contains(field) { return true }
            case .summary: if !summary.contains(field) { return true }
            default: return true
            }
            return line.extras.contains { !names.contains($0) && !days.contains($0) }
        }
    }
}

private extension Optional where Wrapped == [String] {
    var orEmpty: [String] { self ?? [] }
}
