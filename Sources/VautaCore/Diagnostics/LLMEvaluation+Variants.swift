// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// `--variants`: several minutes requests of one backend in one run, interleaved per meeting with the order alternated, as the providers
/// are. A model server is checked once and its key typed once for the whole run, instead of once per arm. Each run is written under the
/// label `<provider>.<variant>` (`server.old`), in the traces and in the result files.
extension LLMEvaluation.Options {
    /// Whether `--variants` accepts the word: `release` (what the app ships for the backend, as `--release`) or a word that each of the
    /// four minutes choices reads (`old`, `new`; `legacy`, `shipped` and `all` are their synonyms).
    public static func isMinutesVariant(_ word: String) -> Bool {
        word.lowercased() == "release" || (MinutesExtraction.parse(word) != nil && MinutesSummary.parse(word) != nil
            && MinutesHarness.parse(word) != nil && MinutesQuestions.parse(word) != nil && !word.isEmpty && !word.contains(","))
    }

    /// The runs of one meeting: the providers, or each provider with each variant.
    var minutesLabels: [String] { variants.isEmpty ? providers : providers.flatMap { p in variants.map { "\(p).\($0)" } } }

    /// The provider of a label and the minutes choices it runs. A variant other than `release` sets the four choices to that word, as
    /// `--extraction old --summary old --harness old --open-questions old` would (the harness applies to the integrated model only).
    func minutesRun(_ label: String) -> (provider: String, choices: (extraction: MinutesExtraction, summary: MinutesSummary, harness: MinutesHarness, questions: MinutesQuestions)) {
        let parts = label.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (label, minutesChoices(provider: label)) }
        var o = self
        if parts[1].lowercased() == "release" {
            o.release = true
        } else {
            o.release = false
            o.extraction = MinutesExtraction.parse(parts[1]) ?? extraction
            o.summary = MinutesSummary.parse(parts[1]) ?? summary
            o.harness = MinutesHarness.parse(parts[1]) ?? harness
            o.openQuestions = MinutesQuestions.parse(parts[1]) ?? openQuestions
        }
        return (parts[0], o.minutesChoices(provider: parts[0]))
    }

    /// The runs of `live-answer`: one per provider, and the model server once per `--ask-reasoning` value when there are two
    /// (`server.reasoning`, `server.plain`), interleaved per question as the providers are. `reasoning` nil is the release choice.
    var answerRuns: [(label: String, kind: String, reasoning: Bool?)] {
        providers.flatMap { p -> [(label: String, kind: String, reasoning: Bool?)] in
            guard p == "server", !askReasoning.isEmpty else { return [(p, p, nil)] }
            if askReasoning.count == 1 { return [(p, p, askReasoning[0])] }
            return askReasoning.map { ("\(p).\($0 ? "reasoning" : "plain")", p, $0) }
        }
    }
}
