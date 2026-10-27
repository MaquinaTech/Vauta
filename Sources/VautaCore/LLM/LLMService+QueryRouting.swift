// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// E4, cross-language retrieval: which text a ranker searches with. The measured rule (docs/SEARCH_MODEL.md): a corpus that ranks by
/// meaning is searched with the question as it was asked (a translated question hurts the semantic ranker slightly), and a corpus
/// that ranks by keywords is searched with the question translated into the corpus's language.
public enum QueryRouting {
    public enum Route: Sendable, Equatable {
        /// Search with the question as asked.
        case original
        /// Translate the question to the corpus's language first (the caller falls back to `original` if it cannot).
        case translate
    }

    /// `question`: the language the question is written in, only when it is known with confidence. `corpus`: the language the
    /// transcripts are in. Only `.keyword` ranking translates: `.semantic` must not see a translated query, and `.rrf` (a model
    /// server's vectors fused with keywords) takes one query for both halves, so it keeps the original.
    public static func route(mode: SemanticRanker.Mode, question: Locale.Language?, corpus: Locale.Language?) -> Route {
        guard mode == .keyword, let question, let corpus, !question.isSameLanguage(as: corpus) else { return .original }
        return .translate
    }
}

extension LLMService {
    /// The text and language to give a keyword ranker.
    struct RoutedQuery: Sendable, Equatable {
        var text: String
        var locale: Locale?
        var translated: Bool
    }

    /// Lets Ask and the live gate translate a question that is in another language than the transcripts when the corpus ranks by
    /// keywords. nil turns it off (the question is always searched as asked). The backend must run on this Mac and use installed
    /// languages only (`AppleTranslationBackend`).
    public func setQueryTranslation(_ backend: (any TranslationBackend)?) {
        queryTranslator = backend.map(QueryTranslator.init(backend:))
    }

    /// The language of the transcripts a search runs over: the meeting's, or the one language of the whole library.
    func corpusLanguage(meeting: MeetingStore.Meeting?, wholeLibrary: Bool) async -> Locale.Language? {
        if let meeting { return meeting.transcriptionLocale.language }
        return wholeLibrary ? try? await store.singleTranscriptionLanguage() : nil
    }

    /// The query for a corpus ranked in `mode`: the question itself, or its translation into `corpus` when `QueryRouting` says so and the
    /// translation is available. Falls back to the question when the pair is not installed, the translation fails or is late, or the
    /// calling task is cancelled.
    func routedQuery(_ question: String, mode: SemanticRanker.Mode, corpus: Locale.Language?, locale: Locale?,
                     timeout: Duration = QueryTranslator.askTimeout) async -> RoutedQuery {
        let original = RoutedQuery(text: question, locale: locale, translated: false)
        // No time left (a shared deadline that was used up): the question as asked, and the translator is not counted as late again.
        guard let queryTranslator, let corpus, timeout > .zero else { return original }
        let asked = OutputLanguage.confident(question).map { Locale(identifier: $0.identifier).language }
        guard QueryRouting.route(mode: mode, question: asked, corpus: corpus) == .translate, let asked,
              let text = await queryTranslator.translate(question, from: asked, to: corpus, timeout: timeout) else { return original }
        return RoutedQuery(text: text, locale: Locale(identifier: corpus.minimalIdentifier), translated: true)
    }
}
