// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A language model that answers nothing: the retrieval tasks use the app's services without one.
private struct NoChat: ChatModel {
    var contextTokens: Int? { 4_096 }
    func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult {
        throw LLMError.modelUnavailable
    }
}

extension EvaluationModel {
    static let retrievalOnly = EvaluationModel(name: "none (retrieval only)", kind: "none") { (NoChat(), 4_096, nil, "retrieval only") }
}

extension RetrievalEvaluation {
    /// The store of one query: the earlier sessions whole and ended, the meeting as it stood at the question (not ended).
    struct World {
        let store: MeetingStore
        let directory: URL
        let current: Int64
        let past: [Int64]
        /// Store segment id to `meeting#passage id`.
        let keys: [Int64: String]
        let selfStoreID: Int64?
    }

    static func build(_ q: Query, transcripts: Transcripts) async throws -> World {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-retrieval-eval-\(UUID().uuidString)", isDirectory: true)
        let store = try MeetingStore(directory: directory, keyStore: MemoryKeyStore())
        let locale = Locale(identifier: q.meetingLocale)
        let date = Date(timeIntervalSince1970: 1_104_537_600)
        var keys: [Int64: String] = [:]
        var past: [Int64] = []
        func insert(_ entry: CorpusEntry, at when: Date, ended: Bool) async throws -> (id: Int64, ids: [Int64: Int64]) {
            let transcript = try transcripts.load(entry)
            let id = try await store.startMeeting(at: when, locale: locale, outputLocale: locale)
            var storeID: [Int64: Int64] = [:]
            for l in LLMEvaluation.replayLines(transcript) where entry.upto.map({ l.id <= $0 }) ?? true {
                let sid = try await store.append(Segment(channel: .others, start: l.start, end: l.end, text: l.stored, isFinal: true), to: id)
                keys[sid] = Query.goldKey(entry.meeting, l.id)
                storeID[l.id] = sid
            }
            if ended { try await store.endMeeting(id, at: when.addingTimeInterval(2_700)) }
            return (id, storeID)
        }
        let earlier = Array(q.corpus.dropFirst())
        for (i, entry) in earlier.enumerated() {
            past.append(try await insert(entry, at: date.addingTimeInterval(-Double(earlier.count - i) * 7 * 86_400), ended: true).id)
        }
        let now = try await insert(q.corpus[0], at: date, ended: false)
        return World(store: store, directory: directory, current: now.id, past: past, keys: keys, selfStoreID: q.selfSegment.flatMap { now.ids[$0] })
    }

    /// On-device translation of the queries (Apple's Translation, installed languages only), one translator per pair of languages.
    final class Translations: @unchecked Sendable {
        private let lock = NSLock()
        private var done: [String: String?] = [:]
        private var translators: [String: any Translator] = [:]
        private var failureCount = 0
        /// Read under the lock, like every write.
        var failures: Int { lock.withLock { failureCount } }

        func translate(_ q: Query) async -> String? {
            let key = q.id
            if let known = lock.withLock({ done[key] }) { return known }
            let pair = "\(q.language)>\(q.meetingLanguage)"
            var translator = lock.withLock { translators[pair] }
            if translator == nil {
                translator = try? await AppleTranslationBackend().makeTranslator(from: Locale.Language(identifier: q.language), to: Locale.Language(identifier: q.meetingLanguage))
                if let translator { lock.withLock { translators[pair] = translator } }
            }
            let text = try? await translator?.translate(q.text)
            lock.withLock { done[key] = .some(text); if text == nil { failureCount += 1 } }
            return text
        }
    }

    static var askBudget: ContextBudget { ContextBudget(contextTokens: 4_096) }

    /// The passages that go to Apple's model: the mixer's choice under Ask's count and character limits.
    static func budgeted(_ passages: [RetrievedPassage]) -> [RetrievedPassage] {
        let budget = askBudget
        let sorted = passages.sorted { $0.score > $1.score }
        let choice = KnowledgeMixer.mix(meetings: sorted.map { .init(score: $0.score, characters: $0.segments.reduce(0) { $0 + $1.text.count + 24 }) }, documents: [],
                                         limit: budget.askPassageLimit, documentLimit: budget.docPassageLimit, maxCharacters: budget.askPassageCharacters)
        return choice.meetings.map { sorted[$0] }
    }

    static func chars(_ p: RetrievedPassage) -> Int { p.segments.reduce(0) { $0 + $1.text.count + 24 } }

    /// Passages chosen by MMR on the cosine of their text (E5), within the Ask budget.
    static func mmrSelect(_ candidates: [RetrievedPassage], embedder: any EmbeddingModel) async -> [RetrievedPassage] {
        guard candidates.count > 1,
              let batch = try? await embedder.embed(candidates.map { p in p.segments.map { "\(MeetingStore.chunkLabel($0)): \($0.text)" }.joined(separator: "\n") }, purpose: .document),
              batch.vectors.count == candidates.count else { return budgeted(candidates) }
        let budget = askBudget
        let chosen = mmr(relevance: candidates.map { $0.cosine ?? $0.score }, similarity: { QuestionEvidenceGate.cosine(batch.vectors[$0], batch.vectors[$1]) },
                         count: budget.askPassageLimit, fits: { chosen, next in chosen.reduce(chars(candidates[next])) { $0 + chars(candidates[$1]) } <= budget.askPassageCharacters })
        return chosen.map { candidates[$0] }
    }

    // MARK: Run

    public static func run(_ o: LLMEvaluation.Options, log: @escaping @Sendable (String) -> Void) async throws {
        let r = o.retrieval
        var arms: [Arm] = []
        for name in r.arms {
            guard let arm = Arm.parse(name) else { throw DataError.unreadable("unknown arm \(name)") }
            if arm.embeddings, o.searchModel == nil { log("arm \(name) needs --search-model: skipped"); continue }
            arms.append(arm)
        }
        // By what is embedded, keeping the order the arms were named in within a stage, except that the on-demand arm goes last in its
        // stage (it stores chunks of the current meeting, which an arm that runs after it would then rank by meaning).
        arms = arms.enumerated().sorted { ($0.element.stage, $0.element.onDemand ? 1 : 0, $0.offset) < ($1.element.stage, $1.element.onDemand ? 1 : 0, $1.offset) }.map(\.element)
        if let model = o.searchModel as? EvaluationSearchModel, !r.embeddingCache || r.coldModel { model.cacheEnabled = false }
        let transcripts = Transcripts(root: o.sets)
        var queries: [Query] = []
        for set in r.sets {
            guard let file = queryFile(for: set) else { throw DataError.unreadable("unknown set \(set)") }
            var rows = try loadQueries(file: o.sets.appendingPathComponent(file), set: set)
            if let split = r.split { rows = rows.filter { $0.split == split } }
            if let m = r.maxQueries { rows = Array(rows.prefix(m)) }
            queries += rows
        }
        let directory = o.out.appendingPathComponent("retrieval", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let results = directory.appendingPathComponent("retrieval.jsonl")
        FileManager.default.createFile(atPath: results.path, contents: nil)
        let translations = Translations()
        let started = Date()
        let load0 = LLMEvaluation.load()[0]
        var written = 0, skipped = 0
        for (n, q) in queries.enumerated() {
            let world = try await build(q, transcripts: transcripts)
            defer { try? FileManager.default.removeItem(at: world.directory) }
            let plain = LLMService(store: world.store, providers: EvaluationProviders(.retrievalOnly), searchDefaults: EvaluationDefaults.suite)
            let semantic = o.searchModel.map { LLMService(store: world.store, providers: EvaluationProviders(.retrievalOnly, searchModel: $0), searchDefaults: EvaluationDefaults.suite) }
            await semantic?.forgetSearchModelCoverage()
            var stage = 0
            var recordingStarted = false
            for arm in arms {
                // The state of the store moves forward: earlier sessions are embedded, then the meeting's prefix.
                if arm.stage >= 1, stage < 1, let semantic { for id in world.past { try await semantic.embed(id) }; stage = 1 }
                if arm.stage >= 2, stage < 2, let semantic { try await semantic.embed(world.current); stage = 2 }
                if arm.onDemand {
                    // A question heard in the meeting never embeds the prefix: only the typed questions run the on-demand code.
                    guard !q.live, let semantic else { skipped += 1; continue }
                    if !recordingStarted {
                        await semantic.setRecording(true, meetingID: world.current)
                        await semantic.setEmbedLivePrefixOnDemand(true)
                        recordingStarted = true
                    }
                }
                var text = q.text
                switch arm.query {
                case .original: break
                case .referenceTranslation:
                    guard q.direction != nil, let ref = q.reference else { skipped += 1; continue }
                    text = ref
                case .appleTranslation:
                    guard q.direction != nil, let t = await translations.translate(q) else { skipped += 1; continue }
                    text = t
                }
                let service = arm.embeddings ? semantic ?? plain : plain
                let t0 = Date()
                var row = try await (q.live ? livePath(q, arm: arm, text: text, world: world, service: service, o: o)
                                            : askPath(q, arm: arm, text: text, world: world, service: service, o: o))
                row["ms"] = (Date().timeIntervalSince(t0) * 1000).rounded()
                row["load1"] = LLMEvaluation.load()[0]
                row["arm"] = arm.name
                row["query_kind"] = "\(arm.query)"
                for (k, v) in header(q) { row[k] = v }
                if let d = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) { LLMEvaluation.appendLine(d, to: results); written += 1 }
            }
            if (n + 1) % 25 == 0 { log("retrieval \(n + 1)/\(queries.count) queries, \(written) rows") }
        }
        var summary: [String: Any] = ["queries": queries.count, "rows": written, "skippedArms": skipped, "arms": arms.map(\.name), "sets": r.sets,
                                      "seconds": Date().timeIntervalSince(started).rounded(), "load1Start": load0, "load1End": LLMEvaluation.load()[0],
                                      "translationFailures": translations.failures, "askPassageLimit": askBudget.askPassageLimit,
                                      "askPassageCharacters": askBudget.askPassageCharacters, "sweep": r.sweep,
                                      "liveThresholds": thresholdsJSON(r.liveThresholds)]
        if let model = o.searchModel as? EvaluationSearchModel { summary["embeddingCache"] = ["hits": model.cacheStatistics.hits, "misses": model.cacheStatistics.misses] }
        try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("run.json"))
        log("retrieval: \(written) rows from \(queries.count) queries in \(Int(Date().timeIntervalSince(started))) s")
    }

    static func header(_ q: Query) -> [String: Any] {
        var h: [String: Any] = ["id": q.id, "set": q.set, "path": q.live ? "live" : "ask", "lang_q": q.language, "lang_m": q.meetingLanguage,
                                "answerable": q.answerable, "constructed": q.constructed, "n_gold": q.gold.count,
                                "scope": q.scope == .pastMeetings ? "past" : "this", "meeting": q.meeting]
        if let s = q.split { h["split"] = s }
        if let c = q.category { h["category"] = c }
        if let d = q.direction { h["direction"] = d }
        if let c = q.condition { h["condition"] = c }
        if let a = q.answeredAloud { h["answered_aloud"] = a }
        return h
    }
}
