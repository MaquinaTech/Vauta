// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// `llm-eval --tasks retrieval`: EVALUATION ONLY, no language model. For each query of a public evaluation set it builds a throwaway store
/// with the meeting as it stood when the question was asked (the transcript up to the question; the earlier sessions of the series whole),
/// runs the app's own retrieval (`LLMService.queryVector`, `meetingRankingMode`, `MeetingStore.retrieve`, `KnowledgeMixer.mix`,
/// `LLMService.questionEvidence`) and writes one JSON line per query and arm: where the gold segments are among the passages, within
/// Apple's Ask budget and at ranks 1 to 10, and what the evidence gate saw (raw cosine and shared words of every passage, so the
/// threshold can be swept offline). It reads public transcripts and questions and writes counts and ids, never transcript text.
///
/// The arms differ in what is embedded and in the query:
///
/// | Arm | Embeddings | Earlier sessions | Meeting being recorded | Query |
/// |---|---|---|---|---|
/// | K | off | none | none | as asked (today without the search model) |
/// | S | on | embedded | not embedded (as shipped: a meeting is embedded once it ends) | as asked |
/// | S3 | on | embedded | the visible prefix embedded (E3 simulated) | as asked |
/// | T / Tref | off | none | none | translated into the meeting's language (T: on-device translator, Tref: the reference translation) |
/// | S3T / S3Tref | on | embedded | prefix embedded | translated |
/// | S3MMR | on | embedded | prefix embedded | as asked, passages chosen with MMR (E5) |
/// | S3leak | on | embedded | prefix embedded | as asked, without removing the question's own line from the score (measures the self-match) |
/// | S3od | on | embedded | the closed chunks embedded by the app's on-demand code (`LLMService.embedLivePrefix`, E3), when the question is typed and the lines do not fit Apple's window | as asked |
///
/// S3od is the only arm that does not simulate the prefix: it calls the code Ask calls, with the service recording the meeting, and records what that
/// cost (`ondemand` in each row: chunks embedded and reused, seconds, CPU energy of this process, peak footprint, and a second call that must embed
/// nothing). It covers typed questions only (a question heard in the meeting never embeds the prefix). The vector cache of `EvaluationSearchModel` would
/// hide the cost, so measure it with `--no-embedding-cache` (and `--cold-model` to include loading the model, as in the app during a recording).
public enum RetrievalEvaluation {
    public struct Options: Sendable {
        /// Arm names (see the table above).
        public var arms: [String] = ["K", "S", "S3"]
        /// Which sets to read from the data folder: w11, w11-stress, w10, cross.
        public var sets: [String] = ["w11", "w10", "cross"]
        public var split: String?
        /// At most this many queries per set (a smoke run).
        public var maxQueries: Int?
        /// Controls to run (`retrieval-controls`): miracl_es, miracl_en, miracl_ja, mlqa_es_to_en, mlqa_en_to_es.
        public var controls: [String] = ["miracl_es", "miracl_en", "miracl_ja", "mlqa_es_to_en", "mlqa_en_to_es"]
        /// Cosine thresholds of the gate sweep.
        public var sweep: [Double] = [0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8]
        /// The thresholds the live path uses for `passing` and the budget recall of its rows (the app's own by default).
        public var liveThresholds = QuestionEvidenceGate.Thresholds.calibrated
        /// `--no-embedding-cache`: every text is embedded by the model (the cache of `EvaluationSearchModel` is off), so S3od's cost is real.
        public var embeddingCache = true
        /// `--cold-model`: the search model is unloaded before each S3od question, so the first question pays the load (the app unloads it
        /// after 3 idle minutes and does not load it during a recording). Implies no cache.
        public var coldModel = false
        public init() {}
    }

    // MARK: Arms

    public enum QueryKind: Sendable { case original, appleTranslation, referenceTranslation }

    public struct Arm: Sendable, Equatable {
        public let name: String
        public let embeddings: Bool
        public let embedsCurrent: Bool
        public let query: QueryKind
        public let mmr: Bool
        public let excludeSelf: Bool
        /// The meeting being recorded is embedded by the app's on-demand code when the question is asked, not beforehand.
        public let onDemand: Bool

        /// 0: no embeddings; 1: earlier sessions embedded; 2: the prefix of the meeting too.
        var stage: Int { embedsCurrent ? 2 : embeddings ? 1 : 0 }

        public static func parse(_ name: String) -> Arm? {
            func make(_ embeddings: Bool, _ current: Bool, _ query: QueryKind = .original, mmr: Bool = false, excludeSelf: Bool = true, onDemand: Bool = false) -> Arm {
                Arm(name: name, embeddings: embeddings, embedsCurrent: current, query: query, mmr: mmr, excludeSelf: excludeSelf, onDemand: onDemand)
            }
            switch name {
            case "K": return make(false, false)
            case "S": return make(true, false)
            case "S3": return make(true, true)
            case "T": return make(false, false, .appleTranslation)
            case "Tref": return make(false, false, .referenceTranslation)
            case "S3T": return make(true, true, .appleTranslation)
            case "S3Tref": return make(true, true, .referenceTranslation)
            case "S3MMR": return make(true, true, mmr: true)
            case "S3leak": return make(true, true, excludeSelf: false)
            case "S3od": return make(true, false, onDemand: true)
            default: return nil
            }
        }
    }

    // MARK: Metrics (pure)

    public struct Metrics: Sendable, Equatable {
        public var recallAt: [Int: Double] = [:]
        public var hitAt: [Int: Double] = [:]
        public var mrr = 0.0
    }

    /// Gold-segment recall and hit at the ranks `ks`, and the reciprocal rank of the first passage that holds a gold segment.
    /// `ranked`: the passages in rank order, each as the keys of its segments. nil when there is no gold.
    public static func metrics(gold: Set<String>, ranked: [[String]], ks: [Int] = [1, 3, 5, 10]) -> Metrics? {
        guard !gold.isEmpty else { return nil }
        var out = Metrics()
        for k in ks {
            let covered = Set(ranked.prefix(k).flatMap { $0 }).intersection(gold)
            out.recallAt[k] = Double(covered.count) / Double(gold.count)
            out.hitAt[k] = covered.isEmpty ? 0 : 1
        }
        if let first = ranked.firstIndex(where: { !gold.isDisjoint(with: $0) }) { out.mrr = 1 / Double(first + 1) }
        return out
    }

    /// Gold-segment recall of a set of passages (the ones that fit the budget).
    public static func recall(gold: Set<String>, passages: [[String]]) -> Double? {
        guard !gold.isEmpty else { return nil }
        return Double(Set(passages.flatMap { $0 }).intersection(gold).count) / Double(gold.count)
    }

    /// Maximal marginal relevance (E5): repeatedly the candidate with the best `lambda * relevance - (1 - lambda) * (largest similarity to
    /// one already chosen)` among those that `fits` (given the ones chosen), up to `count`. Returns indexes into the candidates.
    public static func mmr(relevance: [Double], similarity: (Int, Int) -> Double, count: Int, lambda: Double = 0.7,
                           fits: ([Int], Int) -> Bool = { _, _ in true }) -> [Int] {
        var chosen: [Int] = []
        var left = Array(relevance.indices)
        while chosen.count < count {
            var best: (index: Int, score: Double)?
            for c in left where fits(chosen, c) {
                let redundancy = chosen.map { similarity(c, $0) }.max() ?? 0
                let score = lambda * relevance[c] - (1 - lambda) * redundancy
                if best == nil || score > best!.score { best = (c, score) }
            }
            guard let best else { break }
            chosen.append(best.index)
            left.removeAll { $0 == best.index }
        }
        return chosen
    }
}
