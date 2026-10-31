// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// S4: what the sources hold for a question, found without a model. A source passes when a passage matches at least two distinct
/// content words of the question or, when the search model ranks by meaning, has a raw cosine (no keyword or recency boosts) of at
/// least the source's threshold (`QuestionEvidenceGate.Thresholds`).
public struct QuestionEvidence: Sendable {
    public var thisMeeting: [RetrievedPassage] = []
    public var past: [RetrievedPassage] = []
    public var documents: [DocumentPassage] = []
    /// The meetings the question named that `past` comes from ("last week", "the last meeting"); `.everywhere` when it named none or
    /// nothing there matched.
    public var pastScope = AskMeetingScope.everywhere
    /// The sources that passed the gate.
    public var passing: LiveAnswerSources = []
    /// The source with the strongest passage (nil when none passed).
    public var best: LiveAnswerSources?
    /// Distinct content words the best passage of each source shared with the question (for the diagnostics; no text).
    public var matches: [String: Int] = [:]
    public var elapsed: Double = 0
    /// The question's vector when the search model embedded it (the duplicate memory compares it).
    public var queryVector: [Float]?
    /// What each source found before the gate emptied the sources that did not pass, with whether it was ranked by meaning (for the
    /// evaluation that calibrates the thresholds; the app does not read it).
    public var ungated = Ungated()

    public struct Ungated: Sendable {
        public var thisMeeting: [RetrievedPassage] = []
        public var past: [RetrievedPassage] = []
        public var documents: [DocumentPassage] = []
        public var semantic: LiveAnswerSources = []
    }

    public var passes: Bool { !passing.isEmpty }

    public init() {}
}

/// The gate's arithmetic, apart from retrieval so it can be tested with plain strings.
public enum QuestionEvidenceGate {
    /// E2: the raw cosine from which a passage counts even with few shared words. One place for every threshold of the gate. Two
    /// unrelated texts have a mean cosine of about 0.53 and 0.64 at the 99th percentile (docs/SEARCH_MODEL.md), so the earlier 0.45,
    /// compared with a score that also carried the keyword boosts, let nearly everything through.
    ///
    /// `provisionalThreshold` (0.65, `SemanticRanker.relatedFloor`, the measured floor of random pairs) is the start of the evaluation's
    /// sweep. It sits on top of the distribution of unrelated meetings (43% / 48% of them pass), so no source uses it.
    public static let provisionalThreshold = 0.65

    /// Documents: no evaluation set covers them, so they take the value of the meetings until one does.
    public static let provisionalDocumentThreshold = 0.70

    /// E2 (`llm-eval --tasks retrieval`, raw cosine of the best passage of the source). The value comes from rejecting unrelated
    /// meetings: 13% / 4% (development / held out) of them pass at 0.70, against 43% / 48% at 0.65, while heard questions of the same
    /// language still pass (0.90 / 0.85). The cosine cannot do more: a meeting on the same subject that does not hold the answer scores
    /// as high as one that does (AUC 0.77 and 0.69; 0.70 and 0.43 for questions the series never answered), so those are for answer
    /// verification to catch. 0.78, calibrated on typed questions, passed only 24% / 5% of heard answerable questions. Past meetings
    /// reuse the value: the evaluation holds too few past-meeting questions to calibrate them apart (docs/SEARCH_MODEL.md, E2).
    public static let calibratedMeetingThreshold = 0.70

    /// The raw-cosine threshold of each source (this meeting, past meetings, documents).
    public struct Thresholds: Sendable, Equatable {
        public var thisMeeting: Double
        public var pastMeetings: Double
        public var documents: Double

        public init(thisMeeting: Double = QuestionEvidenceGate.calibratedMeetingThreshold, pastMeetings: Double = QuestionEvidenceGate.calibratedMeetingThreshold,
                    documents: Double = QuestionEvidenceGate.provisionalDocumentThreshold) {
            self.thisMeeting = thisMeeting
            self.pastMeetings = pastMeetings
            self.documents = documents
        }

        /// What the app uses.
        public static let calibrated = Thresholds()

        /// The pre-calibration value for every source (the evaluation sweeps from it).
        public static let provisional = Thresholds.all(QuestionEvidenceGate.provisionalThreshold)

        /// The same value for every source (an evaluation sweep).
        public static func all(_ value: Double) -> Thresholds { Thresholds(thisMeeting: value, pastMeetings: value, documents: value) }
    }

    public static let minimumMatches = 2

    /// What a passage is compared with the threshold by: its raw cosine, never the ranking score (which carries the +0.30, +0.15,
    /// +0.08 and +0.04 boosts of `SemanticRanker`). A passage without one (no vector yet, so it was ranked by keywords) cannot pass on
    /// the cosine path: it passes on shared words alone.
    static func gateScore(cosine: Double?) -> Double { cosine ?? -.infinity }

    /// Cosine of two vectors of the same length (0 when they differ in length or either is null).
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Two words are the same for the gate when they are equal or share a long prefix ("approve", "approved", "approval").
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        let shorter = min(x.count, y.count)
        guard shorter >= 5 else { return false }
        var common = 0
        while common < shorter, x[common] == y[common] { common += 1 }
        return common >= max(5, shorter - 2)
    }

    /// How many distinct content words of the question the text has.
    public static func matches(queryKeys: Set<String>, text: String, locale: String) -> Int {
        guard !queryKeys.isEmpty else { return 0 }
        let words = QuestionDedup.keys(text, locale: locale)
        return queryKeys.filter { key in words.contains { sameWord(key, $0) } }.count
    }

    /// `cosine`: the raw cosine of the passage (see `gateScore`); it only counts when the search model ranks (`semantic`).
    public static func passes(matches: Int, cosine: Double, semantic: Bool, threshold: Double = provisionalThreshold) -> Bool {
        matches >= minimumMatches || (semantic && cosine >= threshold)
    }
}

extension LLMService {
    /// Where a passage cut at the question ends: where the first line cut off begins, never before the last line that is kept and never
    /// after the passage's own end.
    static func cutEnd(of passage: RetrievedPassage, kept: [CitableSegment], allowed: Set<Int64>) -> Double {
        let lastStart = kept[kept.count - 1].start
        guard let next = passage.segments.first(where: { !allowed.contains($0.id) && $0.start >= lastStart }) else { return lastStart }
        return max(lastStart, min(passage.end, next.start))
    }

    /// Looks for evidence for a question in the sources that are on. `segmentID`: the question's own line; the lines of this meeting
    /// from two before it on are left out (a question always matches itself), and so is their effect on the score: a passage that held
    /// them is scored again without them (`cosineWithoutQuestion`; `excludeSelfMatch: false` is for the evaluation that measures the leak). With the search model ranking, a source passes on the passage's raw
    /// cosine against its own threshold (`thresholds`), never on the ranking score.
    public func questionEvidence(text: String, locale: String, meetingID: Int64, segmentID: Int64?, sources: LiveAnswerSources,
                                 thresholds: QuestionEvidenceGate.Thresholds = .calibrated, embed: Bool = true,
                                 excludeSelfMatch: Bool = true) async -> QuestionEvidence {
        let start = ContinuousClock.now
        var evidence = QuestionEvidence()
        let meeting = try? await store.meeting(meetingID)
        let language = OutputLanguage.detect(text, fallback: meeting.map(OutputLanguage.init(meeting:)) ?? OutputLanguage(Locale(identifier: locale)))
        let queryLocale = Locale(identifier: language.identifier)
        let keys = QuestionDedup.keys(text, locale: language.identifier)
        // The search model embeds the question (about a second); with keywords or a server's embeddings the gate stays on the CPU.
        let query = embed && providers.settings.embeddings == .onDeviceModel ? try? await queryVector(text, language: language) : nil

        evidence.queryVector = query?.vector

        func record(_ source: LiveAnswerSources, name: String, matched: Int, cosine: Double, semantic: Bool, threshold: Double) {
            evidence.matches[name] = max(evidence.matches[name] ?? 0, matched)
            if QuestionEvidenceGate.passes(matches: matched, cosine: cosine, semantic: semantic, threshold: threshold) { evidence.passing.insert(source) }
        }
        var bestRank: (matches: Int, score: Double)?
        func consider(_ source: LiveAnswerSources, matched: Int, score: Double) {
            guard evidence.passing.contains(source) else { return }
            if bestRank == nil || (matched, score) > (bestRank!.matches, bestRank!.score) { bestRank = (matched, score); evidence.best = source }
        }

        // One deadline for the translations of the two sources, not one each: a late translation must not make a heard question wait twice.
        let translationDeadline = ContinuousClock.now + QueryTranslator.liveTimeout
        func translationBudget() -> Duration { max(.zero, translationDeadline - ContinuousClock.now) }

        if sources.contains(.thisMeeting), let segmentID {
            let all = (try? await store.citableSegments(meetingID)) ?? []
            let upTo = all.filter { $0.id <= segmentID }
            // Leave out the question's own line and the two before it.
            let allowed = Set(upTo.dropLast(min(3, upTo.count)).map(\.id))
            if !allowed.isEmpty {
                let mode = await meetingRankingMode(space: query?.space, within: meetingID, heardLive: true)
                // E4: when this meeting ranks by keywords, the question is searched translated into its language (shared words are
                // then counted in that language too); when it ranks by meaning, as it was heard.
                let routed = await routedQuery(text, mode: mode, corpus: meeting?.transcriptionLocale.language, locale: queryLocale, timeout: translationBudget())
                let sourceKeys = routed.translated ? QuestionDedup.keys(routed.text, locale: routed.locale?.identifier ?? language.identifier) : keys
                let sourceLocale = routed.translated ? routed.locale?.identifier ?? language.identifier : language.identifier
                let found = (try? await store.retrieve(routed.text, queryVector: query?.vector, within: meetingID, space: query?.space, limit: 4, maxChars: 6_000,
                                                       locale: routed.locale, mode: mode)) ?? []
                // A passage cut at the question keeps the span of the lines that are left, not the one it was found with (a line has no end
                // time here, so the span runs to where the first line that was cut off begins).
                var bounded: [RetrievedPassage] = []
                for p in found {
                    let kept = p.segments.filter { allowed.contains($0.id) }
                    guard !kept.isEmpty else { continue }
                    var cut = RetrievedPassage(meeting: p.meeting, start: kept.count == p.segments.count ? p.start : kept[0].start,
                                               end: kept.last == p.segments.last ? p.end : Self.cutEnd(of: p, kept: kept, allowed: allowed), segments: kept,
                                               score: p.score, cosine: p.cosine)
                    // The passage held the question itself (or what was said after it): its cosine is partly the question's own words.
                    // Score what is left of it, so the question never finds itself.
                    if mode == .semantic, excludeSelfMatch, kept.count < p.segments.count, let query, let before = p.cosine {
                        let own = await cosineWithoutQuestion(kept: kept, query: query, language: language)
                        cut.score += own - before
                        cut.cosine = own
                    }
                    bounded.append(cut)
                }
                if mode == .semantic { bounded.sort { $0.score > $1.score } }
                evidence.thisMeeting = bounded
                if mode == .semantic { evidence.ungated.semantic.insert(.thisMeeting) }
                for p in bounded {
                    let m = QuestionEvidenceGate.matches(queryKeys: sourceKeys, text: p.segments.map(\.text).joined(separator: " "), locale: sourceLocale)
                    record(.thisMeeting, name: "thisMeeting", matched: m, cosine: QuestionEvidenceGate.gateScore(cosine: p.cosine),
                           semantic: mode == .semantic, threshold: thresholds.thisMeeting)
                    consider(.thisMeeting, matched: m, score: p.score)
                }
            }
        }
        if sources.contains(.pastMeetings) {
            let mode = await meetingRankingMode(space: query?.space, within: nil)
            let routed = await routedQuery(text, mode: mode, corpus: await corpusLanguage(meeting: nil, wholeLibrary: true), locale: queryLocale, timeout: translationBudget())
            let sourceKeys = routed.translated ? QuestionDedup.keys(routed.text, locale: routed.locale?.identifier ?? language.identifier) : keys
            let sourceLocale = routed.translated ? routed.locale?.identifier ?? language.identifier : language.identifier
            // The meetings the question names ("what did we decide last week?", "in the last meeting"), read in its words as heard: only
            // there, and in all of them when nothing there matches, as Ask does. A time Ask would only offer is not used: nobody can turn
            // it on here.
            let named = (try? await store.askScope(of: text, languages: [language.identifier, locale], excluding: meetingID)) ?? .everywhere
            func search(_ scope: AskMeetingScope) async -> [RetrievedPassage] {
                (try? await store.retrieve(routed.text, queryVector: query?.vector, within: scope.within, excluding: meetingID, meetings: scope.meetings,
                                           space: query?.space, limit: 3, maxChars: 6_000, locale: routed.locale, mode: mode)) ?? []
            }
            var found = named.narrows ? await search(named) : []
            if found.isEmpty { found = await search(.everywhere) } else { evidence.pastScope = named }
            evidence.past = found
            if mode == .semantic { evidence.ungated.semantic.insert(.pastMeetings) }
            for p in found {
                let m = QuestionEvidenceGate.matches(queryKeys: sourceKeys, text: p.segments.map(\.text).joined(separator: " "), locale: sourceLocale)
                record(.pastMeetings, name: "pastMeetings", matched: m, cosine: QuestionEvidenceGate.gateScore(cosine: p.cosine),
                       semantic: mode == .semantic, threshold: thresholds.pastMeetings)
                consider(.pastMeetings, matched: m, score: p.score)
            }
        }
        if sources.contains(.documents), let documents {
            let mode = await documentRankingMode(space: query?.space, filter: nil)
            let found = (try? await documents.search(text, queryVector: query?.vector, space: query?.space, within: nil, limit: 3, locale: queryLocale,
                                                     entities: [], mode: mode)) ?? []
            evidence.documents = found
            if mode == .semantic { evidence.ungated.semantic.insert(.documents) }
            for p in found {
                let m = QuestionEvidenceGate.matches(queryKeys: keys, text: p.text, locale: language.identifier)
                record(.documents, name: "documents", matched: m, cosine: QuestionEvidenceGate.gateScore(cosine: p.cosine),
                       semantic: mode == .semantic, threshold: thresholds.documents)
                consider(.documents, matched: m, score: p.score)
            }
        }
        evidence.ungated.thisMeeting = evidence.thisMeeting
        evidence.ungated.past = evidence.past
        evidence.ungated.documents = evidence.documents
        // Only the sources that passed go on to the answer.
        if !evidence.passing.contains(.thisMeeting) { evidence.thisMeeting = [] }
        if !evidence.passing.contains(.pastMeetings) { evidence.past = [] }
        if !evidence.passing.contains(.documents) { evidence.documents = [] }
        evidence.elapsed = Double((ContinuousClock.now - start) / .seconds(1))
        return evidence
    }
}

extension LLMService {
    /// The cosine of the question to the lines of a passage that are left after the question's own lines were cut away, embedded as
    /// the chunks are (the same labelled lines, as a document) and rounded the way the index stores a vector, so it is on the scale of
    /// every other passage. It runs at interactive priority: a question is waiting. 0 when the model cannot embed them: a passage that
    /// cannot be scored without the question does not pass on its cosine. (Live chunks are only embedded once the meeting's chunks are
    /// embedded while it records, E3; until then the live meeting ranks by keywords and this is not reached.)
    func cosineWithoutQuestion(kept: [CitableSegment], query: (vector: [Float], space: EmbeddingSpace), language: OutputLanguage) async -> Double {
        // Only the search model on this Mac: the person may have switched to a server's embeddings since the question was embedded, and
        // the lines of a live meeting never go to one.
        guard providers.settings.embeddings == .onDeviceModel, case .available(let model, _) = providers.embeddings(), let embedder = model(Locale(identifier: language.identifier).language) else { return 0 }
        let text = kept.map { "\(MeetingStore.chunkLabel($0)): \($0.text)" }.joined(separator: "\n")
        let batch = try? await SearchModelEngine.$interactiveDocuments.withValue(true) { try await embedder.embed([text], purpose: .document) }
        guard let batch, batch.space == query.space, let vector = batch.vectors.first, vector.allSatisfy(\.isFinite),
              let stored = VectorIndex.asStored(vector) else { return 0 }
        return QuestionEvidenceGate.cosine(query.vector, stored)
    }
}
