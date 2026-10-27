// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import NaturalLanguage

/// S5: the small model call that decides whether a candidate asks for information that notes, earlier meetings or documents could
/// hold, and rewrites it so it stands alone. The prompt, the schema and the parser live here; the call is `LLMService.checkQuestion`.
public struct QuestionCheck: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case information, opinion, request, rhetorical, social
        case notQuestion = "not_question"
    }

    public let kind: Kind
    /// The question rewritten to stand alone, in its own language (empty unless `kind` is `information`).
    public let question: String
    public let answeredAloud: Bool

    public init(kind: Kind, question: String, answeredAloud: Bool) {
        self.kind = kind
        self.question = question
        self.answeredAloud = answeredAloud
    }

    /// The question is worth looking up: an information question with a rewrite, not answered in the next lines (when the person
    /// keeps that suppression on).
    public func proceeds(hideWhenAnsweredAloud: Bool) -> Bool {
        kind == .information && !question.isEmpty && !(hideWhenAnsweredAloud && answeredAloud)
    }

    /// The most the rewrite may be.
    public static let maxQuestionCharacters = 160

    /// The most bytes the grammar lets the rewrite have: about 96 tokens of text fit the integrated model's budget (see
    /// `LLMService.checkGemmaTokens`), which is 160 characters of Latin text and about 80 of Japanese, Korean or Chinese.
    public static let maxQuestionBytes = 240

    /// Reads the model's reply. Fails closed: anything that is not the object, with a known kind, is nil. A rewrite that is not a
    /// question (a description such as "The marked line asks about...") is dropped: the check then says there is nothing to look up.
    /// `candidate`: the sentence that was judged. A rewrite left empty means the sentence already stands alone (it saves the model the
    /// words of a copy), so the sentence itself is the question.
    public static func parse(_ content: String, candidate: String? = nil, language: CueLanguage? = nil) -> QuestionCheck? {
        struct Wire: Decodable {
            let kind: String?
            let question: String?
            let answered_aloud: Bool?
        }
        guard let wire = try? ModelOutput.decodeObject(Wire.self, from: content),
              let word = wire.kind?.trimmingCharacters(in: .whitespaces).lowercased(), let kind = Kind(rawValue: word) else { return nil }
        let text = SingleLineText.flatten(wire.question ?? "")
        var question = kind == .information ? String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestionCharacters)) : ""
        if kind == .information, question.isEmpty, let candidate {
            question = String(SingleLineText.flatten(candidate).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestionCharacters))
        }
        if !question.isEmpty, !isQuestion(question, language: language) { question = "" }
        // The rewrite stays in the language of the sentence: a model that translated it (Gemma wrote Spanish rewrites of English
        // questions) would make the answer follow the translation. The sentence itself is the safe question then.
        if !question.isEmpty, let candidate, let said = OutputLanguage.confident(candidate), let written = OutputLanguage.confident(question),
           !said.sameLanguage(as: written) {
            question = String(SingleLineText.flatten(candidate).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestionCharacters))
        }
        return QuestionCheck(kind: kind, question: question, answeredAloud: wire.answered_aloud ?? false)
    }

    /// Whether a rewrite is a question: it has a question mark, or its own words open like one (an interrogative, a question particle).
    /// `language`: the candidate's own language (the meeting's), tried first; the recognizer's guess is the second try.
    static func isQuestion(_ text: String, language preferred: CueLanguage? = nil) -> Bool {
        // A mark counts at the end or as the opening "¿"; a description that quotes a question (`The speaker asks "how much?"`,
        // `El hablante pregunta: ¿cuánto?`) does not.
        let quoted = text.contains { "\"“„«".contains($0) } || text.contains(":")
        if !quoted, QuestionCues.endsWithQuestionMark(text) || text.hasPrefix("¿") { return true }
        func asks(_ language: CueLanguage) -> Bool {
            // The short-sentence weight is left out: "Quién lo firmó" is three words and still a question.
            let scored = QuestionCues.score(sentence: text, language: language)
            let short = scored.cues.contains("short") ? QuestionCues.Weight.short : 0
            // A mark inside a quotation says nothing about the rewrite itself.
            let mark = scored.cues.contains("mark") ? QuestionCues.Weight.questionMark : 0
            return scored.score - short - mark >= Self.minimumRewriteScore
                || !Set(scored.cues).isDisjoint(with: ["interrogative", "embedded", "particle"])
        }
        if let preferred, asks(preferred) { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage, let language = CueLanguage(identifier: dominant.rawValue) else { return false }
        return asks(language)
    }

    /// A rewrite with no question mark must still score as much as an interrogative word alone.
    static let minimumRewriteScore = 0.35

    /// The grammar of the integrated model.
    public static var schema: OutputSchema {
        .object([OutputSchema.Property("kind", .enumStrings(Kind.allCases.map(\.rawValue))),
                 OutputSchema.Property("question", .string(maxBytes: maxQuestionBytes)),
                 OutputSchema.Property("answered_aloud", .boolean)])
    }

    /// The schema a model server's `response_format` gets.
    public static var serverSchema: OutputSchema { schema }

    /// The instruction: the marked line, three lines before it and the lines after it (at most `maxLinesAfter`). `afterOnly`: the lines
    /// before it are already in the transcript the model has read.
    public static func instruction(for question: SettledQuestion, afterOnly: Bool = false, compact: Bool = false) -> String {
        var lines: [String] = []
        if !afterOnly { lines += question.before.map { $0.promptLine(maxCharacters: lineCharacters) } }
        lines.append(">>> " + question.line.promptLine(maxCharacters: lineCharacters))
        lines += question.after.map { $0.promptLine(maxCharacters: lineCharacters) }
        let block = lines.joined(separator: "\n")
        // The marked line may hold more than the sentence the cues picked: then the sentence is named.
        let sentence = question.candidate.text == question.line.text
            ? "" : "\nThe sentence to judge is: \(PromptText.defang(PromptText.clip(SingleLineText.flatten(question.candidate.text), lineCharacters)))"
        let said = languageRule(question)
        if compact { return compactInstruction(block: block, sentence: sentence, afterOnly: afterOnly, said: said) }
        let context = afterOnly ? "The transcript above holds the lines before it." : "The lines around it are context."
        return """
            The line marked >>> was just said in a meeting being recorded. \(context)
            <<<LINES
            \(block)
            >>>\(sentence)
            Does the marked line ask for a fact that notes, earlier meetings or documents could hold (a figure, a date, a name, a decision, what was said or agreed)?
            kind: information; opinion (asks what people think or prefer); request (asks someone to do something); rhetorical (needs no answer, or the speaker answers it); social (a greeting, a check of audio or screen); not_question (anything else). "What would X mean?" and "How is X organised?" are information, not requests.
            If information, rewrite it as a question that stands alone (replace "it", "that", "he" with what the lines say), \(said); leave it empty if it already stands alone. Never describe or answer it.
            answered_aloud: true only if one of the 3 lines before or the lines after already gives the answer, or the marked line only repeats or confirms what was just said.
            Examples: "How much did it cost?" information; "¿Cuánto costó la obra?" information; "¿Qué significa doble curvatura?" information; "Can you send me the file?" request; "¿Me pasas el acta?" request; "What do you think?" opinion; "¿Qué os parece?" opinion; "Who would have thought?" rhetorical; "Can you hear me?" social; "¿Se oye bien?" social.
            Reply with one JSON object: {"kind": "information" | "opinion" | "request" | "rhetorical" | "social" | "not_question", "question": "...", "answered_aloud": true | false}.
            """
    }

    /// The integrated model reads the instruction at about 150 tokens a second on every check (it is a suffix, so it is not kept): the same
    /// rules in about a third of the words, with the two languages' examples folded into the kinds.
    static func compactInstruction(block: String, sentence: String, afterOnly: Bool, said: String) -> String {
        let context = afterOnly ? "The transcript above holds the lines before it." : "The lines around it are context."
        return """
            The line marked >>> was just said in a meeting. \(context)
            <<<LINES
            \(block)
            >>>\(sentence)
            kind: information (asks for a fact notes or documents could hold: a figure, a date, a name, a decision, what was said, what a term means, how something is organised; "¿Cuánto costó la obra?", "¿Qué significa X?"); opinion ("What do you think?", "¿Qué os parece?"); request ("Can you send the file?", "¿Me pasas el acta?"); rhetorical; social (greeting, "Can you hear me?", "¿Se oye bien?"); not_question.
            question: for information only, a rewrite that stands alone and is still a question, \(said); "" if it already stands alone. Never describe or answer it.
            answered_aloud: true if the 3 lines before or the lines after give the answer, or only repeat or confirm the question.
            Reply with JSON: {"kind": "...", "question": "...", "answered_aloud": true | false}.
            """
    }

    /// Where the prompt names the language of the rewrite: the language of the sentence (the recognizer's, else the meeting's), never
    /// a translation. The examples in other languages are only examples.
    static func languageRule(_ question: SettledQuestion) -> String {
        let named = OutputLanguage.confident(question.candidate.text)
            ?? question.candidate.language.map { OutputLanguage(Locale(identifier: $0.rawValue)) }
        guard let named else { return "in the language of the marked line, without translating it" }
        return "in \(named.englishName), the language of the marked line, without translating it"
    }

    /// The characters of a line in the check (a long segment is cut: the model reads the sentence to judge apart).
    static let lineCharacters = 220
}
