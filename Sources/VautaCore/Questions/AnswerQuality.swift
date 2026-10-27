// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Two checks on a verified answer to a question heard, before it can become a card: it must say something the question did not, and it
/// must commit to it. An answer that repeats the question back, or that only says there might be something, is not shown (it is a
/// sealed card that tells the person nothing).
enum AnswerQuality {
    /// The share of an answer's content words that the question already has, from which the answer is the question said again.
    static let repeatShare = 0.8

    /// The fewest content words an answer needs to be judged as a repetition: "Yes, 1991." or a label such as "Pilot" is too short to
    /// say it again.
    static let minimumWords = 3

    /// Whether the text says again what the question said: nearly every content word of it is in one of the question's phrasings.
    static func repeats(_ text: String, questions: [String], locale: String) -> Bool {
        let answer = QuestionDedup.keys(text, locale: locale)
        guard answer.count >= minimumWords else { return false }
        for question in questions {
            let asked = QuestionDedup.keys(question, locale: locale)
            guard !asked.isEmpty else { continue }
            let shared = answer.filter { word in asked.contains { QuestionEvidenceGate.sameWord(word, $0) } }.count
            if Double(shared) / Double(answer.count) >= repeatShare { return true }
        }
        return false
    }

    /// Whether the text only hedges or says nothing was settled ("there might be something else", "not fully discussed").
    static func isVague(_ text: String) -> Bool {
        let folded = " " + TextKeys.norm(text) + " "
        return vaguePhrases.contains { folded.contains(" " + $0 + " ") }
    }

    /// Whether an answer is worth a card: no claim of it is vague, and neither it nor all its claims repeat the question.
    static func acceptable(_ content: AutoAnswerContent, questions: [String], locale: String) -> Bool {
        if isVague(content.answer) || content.claims.contains(where: { isVague($0.text) }) { return false }
        if repeats(content.answer, questions: questions, locale: locale) { return false }
        if !content.claims.isEmpty, content.claims.allSatisfy({ repeats($0.text, questions: questions, locale: locale) }) { return false }
        return true
    }

    /// Phrases (folded: no accents, no punctuation) that mark an answer as a hedge or a non-answer, in the interface languages (Japanese, Korean and Simplified Chinese have none: they are not covered). Phrases that also state a figure
    /// ("algo más de 40.000 euros", "potrebbe") are left out on purpose.
    static let vaguePhrases: [String] = [
        // English
        "may be something", "may be more", "could be something", "there may be", "there might", "possibly", "perhaps",
        "not fully discussed", "not specified", "not stated", "unclear", "no specific", "not been decided",
        "among other things",
        // Spanish
        "podria haber", "puede que", "quizas", "quiza", "tal vez", "posiblemente", "no se discutio por completo",
        "no esta claro", "no queda claro", "no se especifica", "no se menciona", "no se detalla", "entre otras cosas",
        // French
        "il se peut", "pas clair", "pas precise", "pas mentionne",
        // German
        "vielleicht", "moglicherweise", "nicht klar", "nicht angegeben", "nicht erwahnt",
        // Italian
        "forse", "non e chiaro", "non specificato", "non menzionato",
        // Portuguese
        "talvez", "nao esta claro", "nao especificado", "nao mencionado",
    ]
}
