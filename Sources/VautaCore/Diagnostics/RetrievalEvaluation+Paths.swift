// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import VautaMLX

extension RetrievalEvaluation {
    /// What one source found, for the gate.
    struct GateInput {
        let source: String
        let passages: [RetrievedPassage]
        let semantic: Bool
    }

    static func segmentKeys(_ p: RetrievedPassage, _ world: World) -> [String] { p.segments.compactMap { world.keys[$0.id] } }

    /// The row of one passage: its raw cosine, ranking score, shared content words with the question, and gold segments (ids and counts only).
    static func passageRow(_ p: RetrievedPassage, source: String, matches: Int, gold: Set<String>, world: World) -> [String: Any] {
        var row: [String: Any] = ["src": source, "score": p.score, "m": matches, "gold": Set(segmentKeys(p, world)).intersection(gold).count,
                                  "chars": chars(p), "segments": p.segments.count]
        if let c = p.cosine { row["cos"] = c }
        return row
    }

    /// Whether the whole visible meeting fits Apple's window with the question (then Ask sends it whole and retrieves nothing).
    static func fitsWhole(_ q: Query, text: String, world: World) async -> Bool {
        var segments = (try? await world.store.citableSegments(world.current)) ?? []
        if q.live, let id = world.selfStoreID { segments = segments.filter { $0.id < id } }
        return !segments.isEmpty && PromptText.tokens([.system(VautaPrompts.system), VautaPrompts.transcriptMessage(segments), .user(text)]) <= askBudget.askInput
    }

    /// The gate at each threshold of the sweep: which sources pass on the raw cosine (or two shared words), and what is left of the
    /// passages that go to Apple's model when only those sources count.
    static func sweep(_ inputs: [GateInput], matches: [[Int]], taus: [Double], gold: Set<String>, world: World) -> [String: Any] {
        var out: [String: Any] = [:]
        for tau in taus {
            var passing: [String] = []
            var kept: [RetrievedPassage] = []
            for (i, input) in inputs.enumerated() {
                let ok = zip(input.passages, matches[i]).contains { QuestionEvidenceGate.passes(matches: $1, cosine: QuestionEvidenceGate.gateScore(cosine: $0.cosine),
                                                                                                 semantic: input.semantic, threshold: tau) }
                if ok { passing.append(input.source); kept += input.passages }
            }
            var entry: [String: Any] = ["pass": passing]
            if let recall = recall(gold: gold, passages: budgeted(kept).map { segmentKeys($0, world) }) { entry["recall"] = recall }
            out[String(format: "%.2f", tau)] = entry
        }
        return out
    }

    /// The thresholds as written to the results (`passing` and the live budget depend on them).
    static func thresholdsJSON(_ t: QuestionEvidenceGate.Thresholds) -> [String: Double] {
        ["thisMeeting": t.thisMeeting, "pastMeetings": t.pastMeetings, "documents": t.documents]
    }

    static func rankRow(_ m: Metrics) -> [String: Any] {
        ["recall": Dictionary(uniqueKeysWithValues: m.recallAt.map { (String($0.key), $0.value) }),
         "hit": Dictionary(uniqueKeysWithValues: m.hitAt.map { (String($0.key), $0.value) }), "mrr": m.mrr]
    }

    /// A question the person typed (the Ask path): `queryVector`, the ranking mode, `MeetingStore.retrieve` with Apple's count and
    /// character limits and the mixer, as `LLMService.ask` calls them for a meeting that does not fit whole.
    static func askPath(_ q: Query, arm: Arm, text: String, world: World, service: LLMService, o: LLMEvaluation.Options) async throws -> [String: Any] {
        let budget = askBudget
        let language = OutputLanguage.detect(text, fallback: OutputLanguage(Locale(identifier: q.meetingLocale)))
        // S3od: the app's own on-demand code, in the order Ask runs it (before the question is embedded).
        let onDemand = arm.onDemand ? try await prefixStep(q, text: text, world: world, service: service, o: o) : nil
        let query = try await service.queryVector(text, language: language)
        let within: Int64? = q.scope == .thisMeeting ? world.current : nil
        let excluding: Int64? = q.scope == .pastMeetings ? world.current : nil
        let mode = await service.meetingRankingMode(space: query?.space, within: within)
        let locale = Locale(identifier: language.identifier)
        let ranked = try await world.store.retrieve(text, queryVector: query?.vector, within: within, excluding: excluding, space: query?.space, limit: 10,
                                                    maxChars: 1_000_000, locale: locale, mode: mode)
        let found = try await world.store.retrieve(text, queryVector: query?.vector, within: within, excluding: excluding, space: query?.space,
                                                   limit: budget.askPassageLimit, maxChars: budget.askPassageCharacters, locale: locale, mode: mode)
        var sent = budgeted(found)
        if arm.mmr, let embedder = o.searchModel { sent = await mmrSelect(ranked, embedder: embedder) }
        var row = await result(q, text: text, language: language, mode: mode, ranked: ranked, sent: sent, inputs: [GateInput(source: "this", passages: ranked, semantic: mode == .semantic)],
                               passing: nil, world: world, o: o)
        if let onDemand { row["ondemand"] = onDemand }
        return row
    }

    /// What `LLMService.ask` does before it embeds a typed question while the meeting is recorded and the lines do not fit: embeds the closed
    /// chunks of the meeting as it stands. Measured around the call: wall time, this process's CPU energy (the GPU's is not in it), the peak
    /// `phys_footprint` and the chunks embedded; then once more, which must embed nothing.
    static func prefixStep(_ q: Query, text: String, world: World, service: LLMService, o: LLMEvaluation.Options) async throws -> [String: Any] {
        guard q.scope == .thisMeeting else { return ["skipped": "scope"] }
        if await fitsWhole(q, text: text, world: world) { return ["skipped": "fitsInContext"] }
        let last = try await world.store.citableSegments(world.current).last?.id ?? 0
        if o.retrieval.coldModel { await (o.searchModel as? EvaluationSearchModel)?.unload() }
        let footprintBefore = MLXRuntime.physFootprintMB()
        let sampler = LLMEvaluation.FootprintSampler()
        sampler.start()
        let usageBefore = LLMEvaluation.rusage()
        let started = Date()
        let report = try await service.embedLivePrefix(meetingID: world.current, upToSegment: last, question: text)
        let wall = Date().timeIntervalSince(started)
        let usageAfter = LLMEvaluation.rusage()
        let peak = sampler.stop()
        let again = try await service.embedLivePrefix(meetingID: world.current, upToSegment: last, question: text)
        var out: [String: Any] = ["closed": report.closedChunks, "embedded": report.embeddedChunks, "reused": report.reusedChunks, "dropped": report.droppedChunks,
                                  "seconds": wall, "cpuJoules": usageAfter.energyJoules - usageBefore.energyJoules,
                                  "cpuSeconds": (usageAfter.userSeconds + usageAfter.systemSeconds) - (usageBefore.userSeconds + usageBefore.systemSeconds),
                                  "footprintBeforeMB": footprintBefore, "peakFootprintMB": peak, "cold": o.retrieval.coldModel,
                                  "startedAt": started.timeIntervalSince1970, "endedAt": started.timeIntervalSince1970 + wall,
                                  "secondEmbedded": again.embeddedChunks, "secondSeconds": again.seconds]
        if let why = report.skipped { out["skipped"] = why.rawValue }
        return out
    }

    /// A question heard in the meeting (the live path): the evidence gate of `LLMService.questionEvidence` with the question's own line in
    /// the transcript, as the app calls it.
    static func livePath(_ q: Query, arm: Arm, text: String, world: World, service: LLMService, o: LLMEvaluation.Options) async throws -> [String: Any] {
        let language = OutputLanguage.detect(text, fallback: OutputLanguage(Locale(identifier: q.meetingLocale)))
        let evidence = await service.questionEvidence(text: text, locale: q.meetingLocale, meetingID: world.current, segmentID: world.selfStoreID,
                                                      sources: [.thisMeeting, .pastMeetings], thresholds: o.retrieval.liveThresholds, embed: true, excludeSelfMatch: arm.excludeSelf)
        let ungated = evidence.ungated
        let ranked = (ungated.thisMeeting + ungated.past).sorted { $0.score > $1.score }
        var sent = budgeted(evidence.thisMeeting + evidence.past)
        if arm.mmr, let embedder = o.searchModel { sent = await mmrSelect(ranked, embedder: embedder) }
        let inputs = [GateInput(source: "this", passages: ungated.thisMeeting, semantic: ungated.semantic.contains(.thisMeeting)),
                      GateInput(source: "past", passages: ungated.past, semantic: ungated.semantic.contains(.pastMeetings))]
        var passing: [String] = []
        if evidence.passing.contains(.thisMeeting) { passing.append("this") }
        if evidence.passing.contains(.pastMeetings) { passing.append("past") }
        var row = await result(q, text: text, language: language, mode: inputs[0].semantic ? .semantic : .keyword, ranked: ranked, sent: sent, inputs: inputs, passing: passing,
                               world: world, o: o)
        row["live_tau"] = thresholdsJSON(o.retrieval.liveThresholds)
        row["mode_past"] = inputs[1].semantic ? "semantic" : "keyword"
        if let v = evidence.queryVector { row["query_embedded"] = !v.isEmpty } else { row["query_embedded"] = false }
        return row
    }

    static func result(_ q: Query, text: String, language: OutputLanguage, mode: SemanticRanker.Mode, ranked: [RetrievedPassage], sent: [RetrievedPassage],
                       inputs: [GateInput], passing: [String]?, world: World, o: LLMEvaluation.Options) async -> [String: Any] {
        let inCorpus = q.gold.intersection(world.keys.values)
        let keys = QuestionDedup.keys(text, locale: language.identifier)
        let matches = inputs.map { input in
            input.passages.map { QuestionEvidenceGate.matches(queryKeys: keys, text: $0.segments.map(\.text).joined(separator: " "), locale: language.identifier) }
        }
        var row: [String: Any] = ["mode": mode == .semantic ? "semantic" : "keyword", "n_gold_in_corpus": inCorpus.count,
                                  "fits_whole": await fitsWhole(q, text: text, world: world), "query_chars": text.count]
        var passages: [[String: Any]] = []
        for (i, input) in inputs.enumerated() {
            for (p, m) in zip(input.passages, matches[i]) { passages.append(passageRow(p, source: input.source, matches: m, gold: inCorpus, world: world)) }
        }
        row["passages"] = passages
        var budget: [String: Any] = ["n": sent.count, "chars": sent.reduce(0) { $0 + chars($1) }]
        if let recall = recall(gold: inCorpus, passages: sent.map { segmentKeys($0, world) }) {
            budget["recall"] = recall
            budget["hit"] = recall > 0 ? 1 : 0
        }
        row["budget"] = budget
        if let m = metrics(gold: inCorpus, ranked: ranked.map { segmentKeys($0, world) }) { row["rank"] = rankRow(m) }
        if let passing { row["passing"] = passing }
        row["gate"] = sweep(inputs, matches: matches, taus: o.retrieval.sweep, gold: inCorpus, world: world)
        return row
    }
}
