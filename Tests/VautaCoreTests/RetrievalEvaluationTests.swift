// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Retrieval evaluation harness")
struct RetrievalEvaluationTests {
    // MARK: Pure parts

    @Test func armsAreParsedAndStagedByWhatIsEmbedded() {
        #expect(RetrievalEvaluation.Arm.parse("K")?.stage == 0 && RetrievalEvaluation.Arm.parse("T")?.stage == 0)
        #expect(RetrievalEvaluation.Arm.parse("S")?.stage == 1)
        #expect(RetrievalEvaluation.Arm.parse("S3")?.stage == 2 && RetrievalEvaluation.Arm.parse("S3MMR")?.mmr == true)
        #expect(RetrievalEvaluation.Arm.parse("S3leak")?.excludeSelf == false)
        #expect(RetrievalEvaluation.Arm.parse("S3Tref")?.query == .referenceTranslation)
        #expect(RetrievalEvaluation.Arm.parse("nope") == nil)
    }

    @Test func recallHitAndReciprocalRankAreCountedOverSegments() throws {
        let ranked = [["a#1", "a#2"], ["a#3"], ["a#9"]]
        let m = try #require(RetrievalEvaluation.metrics(gold: ["a#2", "a#3", "a#7"], ranked: ranked))
        #expect(m.recallAt[1] == 1.0 / 3 && m.recallAt[3] == 2.0 / 3 && m.hitAt[1] == 1 && m.mrr == 1)
        let late = try #require(RetrievalEvaluation.metrics(gold: ["a#9"], ranked: ranked))
        #expect(late.hitAt[1] == 0 && late.hitAt[3] == 1 && late.mrr == 1.0 / 3)
        #expect(RetrievalEvaluation.metrics(gold: [], ranked: ranked) == nil)
        #expect(RetrievalEvaluation.recall(gold: ["a#1", "a#5"], passages: [["a#1"]]) == 0.5)
    }

    @Test func mmrSkipsAPassageThatRepeatsAChosenOneAndKeepsTheBudget() {
        let relevance = [0.9, 0.88, 0.6]
        let similar: (Int, Int) -> Double = { a, b in Set([a, b]) == [0, 1] ? 0.99 : 0.2 }
        #expect(RetrievalEvaluation.mmr(relevance: relevance, similarity: similar, count: 2) == [0, 2])
        #expect(RetrievalEvaluation.mmr(relevance: relevance, similarity: similar, count: 3, lambda: 1) == [0, 1, 2], "lambda 1 is the plain ranking")
        #expect(RetrievalEvaluation.mmr(relevance: relevance, similarity: similar, count: 3, fits: { chosen, next in !(chosen.contains(0) && next == 2) }) == [0, 1])
    }

    @Test func bm25RanksTheDocumentWithTheRareTermsFirst() {
        let docs = [["the", "cat", "sat"], ["budget", "costs", "rose"], ["the", "the", "budget"]]
        let scores = RetrievalEvaluation.bm25(query: ["budget", "costs"], documents: docs)
        #expect(scores[1] > scores[2] && scores[2] > scores[0] && scores[0] == 0)
        #expect(RetrievalEvaluation.bm25(query: ["x"], documents: []).isEmpty)
        let fused = RetrievalEvaluation.rrf([[3, 2, 1], [1, 3, 2]])
        #expect(fused[1] > fused[2], "second place twice beats first and last")
    }

    @Test func controlMetricsMatchTheDefinitions() throws {
        let m = try #require(RetrievalEvaluation.controlMetrics(scores: [0.1, 0.9, 0.5], relevant: [2]))
        #expect(m.hit1 == 0 && m.mrr10 == 0.5 && m.recall3 == 1)
        #expect(abs(m.ndcg10 - 1 / log2(3)) < 1e-9)
        let perfect = try #require(RetrievalEvaluation.controlMetrics(scores: [0.9, 0.5, 0.1], relevant: [0]))
        #expect(perfect.ndcg10 == 1 && perfect.hit1 == 1)
        #expect(RetrievalEvaluation.controlMetrics(scores: [1], relevant: []) == nil)
    }

    // MARK: Providers

    @Test func evaluationEmbeddingsAreOffUnlessASearchModelIsNamed() throws {
        let off = EvaluationProviders(.retrievalOnly)
        #expect(off.settings.embeddings == .none)
        if case .disabled = off.embeddings() {} else { Issue.record("embeddings must be disabled without a search model") }
        let on = EvaluationProviders(.retrievalOnly, searchModel: BudgetedEmbedder(limit: 500))
        #expect(on.settings.embeddings == .onDeviceModel)
        guard case .available(let model, let expected) = on.embeddings() else { Issue.record("embeddings must be available"); return }
        #expect(model(Locale.Language(identifier: "es")) != nil && expected(Locale.Language(identifier: "ja")) == GemmaEmbeddingModel.space.model)
    }

    @Test func anEvaluationNeverWritesToTheStandardDefaults() {
        // The process-wide suite is shared by tests that run in parallel, so it is only read here, never removed.
        let key = "vauta.evaluation.test.\(UUID().uuidString)"
        EvaluationDefaults.suite.set(true, forKey: key)
        defer { EvaluationDefaults.suite.removeObject(forKey: key) }
        #expect(EvaluationDefaults.suite.bool(forKey: key))
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(EvaluationDefaults.name != Bundle.main.bundleIdentifier)
        // Removing a suite of its own leaves no value behind.
        let name = "vauta.evaluation.test.\(UUID().uuidString)"
        let own = UserDefaults(suiteName: name)!
        own.set(true, forKey: key)
        own.removePersistentDomain(forName: name)
        #expect(own.object(forKey: key) == nil)
    }

    @Test func theSearchModelFolderMustBeAnInstallOfThePinnedRevision() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: EvaluationSearchModel.Failure.self) { _ = try await EvaluationSearchModel.open(directory: root) }
        let install = root.appendingPathComponent("embeddinggemma-2/\(SearchModelSpec.pinned.revisionFolder)", isDirectory: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        await #expect(throws: EvaluationSearchModel.Failure.self) { _ = try await EvaluationSearchModel.open(directory: install) }
        try Data("x".utf8).write(to: install.appendingPathComponent("model.safetensors"))
        try Data("x".utf8).write(to: install.appendingPathComponent("tokenizer.json"))
        await #expect(throws: EvaluationSearchModel.Failure.self) { _ = try await EvaluationSearchModel.open(directory: install) }
    }

    // MARK: Data

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retrieval-eval-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("meetings/base"), withIntermediateDirectories: true)
        return url
    }

    static func write(_ lines: [[String: Any]], to url: URL) throws {
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func transcript(_ name: String, _ lines: [String], in root: URL) throws {
        let passages = lines.enumerated().map { i, t -> [String: Any] in ["id": i + 1, "start": Double(i * 10), "end": Double(i * 10 + 8), "speaker": "Speaker \(i % 2 + 1)", "text": t] }
        let object: [String: Any] = ["meeting": name, "language": "en", "source": "test", "passages": passages]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("meetings/base/\(name).json"))
    }

    @Test func queriesOfEverySetAreReadWithTheirGoldAndCorpus() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write([["qid": "M1-q1", "meeting": "M1", "meeting_language": "en", "question_language": "en", "question": "What about the budget?", "category": "fact", "answerable": true,
                         "gold_segments": [2, 3], "corpus": ["base": "base", "meeting": "M1", "upto_segment": 5]]], to: root.appendingPathComponent("w11.jsonl"))
        let w11 = try RetrievalEvaluation.loadQueries(file: root.appendingPathComponent("w11.jsonl"), set: "w11")
        #expect(w11.count == 1 && w11[0].gold == ["M1#2", "M1#3"] && !w11[0].live && w11[0].corpus == [.init(base: "base", meeting: "M1", upto: 5)])
        try Self.write([["id": "M2:4:1", "condition": "A", "meeting": "M2", "language": "en", "split": "dev", "query": "Where is it?", "answerable": "past_meeting", "self_segment_id": 4,
                         "gold_segments": [["meeting": "M1", "segment_id": 2, "in_corpus": true], ["meeting": "M1", "segment_id": 9, "in_corpus": false]], "query_language": "en",
                         "corpus": [["base": "base", "meeting": "M2", "upto_segment": 4], ["base": "base", "meeting": "M1", "upto_segment": NSNull()]]]], to: root.appendingPathComponent("w10.jsonl"))
        let w10 = try RetrievalEvaluation.loadQueries(file: root.appendingPathComponent("w10.jsonl"), set: "w10")
        #expect(w10[0].live && w10[0].selfSegment == 4 && w10[0].scope == .pastMeetings && w10[0].gold == ["M1#2"], "a gold outside the corpus is not counted")
        #expect(w10[0].corpus.count == 2 && w10[0].corpus[1].upto == nil && w10[0].split == "dev")
        try Self.write([["id": "x/x", "source": "w10_constructed", "constructed": true, "query": "¿Dónde está?", "query_language": "es", "meeting_language": "en", "direction": "es->en",
                         "original_query": "Where is it?", "meeting": "M2", "gold_segments": [["meeting": "M1", "segment_id": 2, "in_corpus": true]], "self_segment_id": 4,
                         "corpus": [["base": "base", "meeting": "M2", "upto_segment": 4]], "answerable_kind": "so_far"]], to: root.appendingPathComponent("cross.jsonl"))
        let cross = try RetrievalEvaluation.loadQueries(file: root.appendingPathComponent("cross.jsonl"), set: "cross")
        #expect(cross[0].live && cross[0].reference == "Where is it?" && cross[0].direction == "es->en" && cross[0].constructed)
    }

    // MARK: End to end, with the concept embedder standing in for the search model

    static let past = ["Weekly sync notes", "The Berlin pilot budget was fifty thousand euros", "Maria approved the pilot", "Okay that is all"]
    static let live = ["Good morning everyone", "We reviewed the hiring plan", "The launch rollout is on track", "Costs and spending are fine", "Fine thanks", "What about the hiring plan again?"]

    static func run(arms: [String], root: URL, out: URL) async throws -> [[String: Any]] {
        try transcript("M0", past, in: root)
        try transcript("M1", live, in: root)
        try write([["qid": "M1-q1", "meeting": "M1", "meeting_language": "en", "question_language": "en", "question": "Tell me about recruiting", "category": "fact", "answerable": true,
                    "gold_segments": [2], "corpus": ["base": "base", "meeting": "M1", "upto_segment": 5]]], to: root.appendingPathComponent("w11_questions.jsonl"))
        try write([["id": "M1:6:1", "condition": "A", "meeting": "M1", "language": "en", "split": "dev", "query": "What was the pilot budget in Berlin?", "answerable": "past_meeting",
                    "self_segment_id": 6, "gold_segments": [["meeting": "M0", "segment_id": 2, "in_corpus": true]], "query_language": "en",
                    "corpus": [["base": "base", "meeting": "M1", "upto_segment": 6], ["base": "base", "meeting": "M0", "upto_segment": NSNull()]]]],
                  to: root.appendingPathComponent("w10_information.jsonl"))
        var o = LLMEvaluation.Options(sets: root, out: out)
        o.tasks = ["retrieval"]
        o.retrieval.arms = arms
        o.retrieval.sets = ["w11", "w10"]
        o.searchModel = BudgetedEmbedder(limit: 500)
        try await RetrievalEvaluation.run(o, log: { _ in })
        let text = try String(contentsOf: out.appendingPathComponent("retrieval/retrieval.jsonl"), encoding: .utf8)
        return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    @Test func eachArmRunsTheAppsRetrievalOnTheMeetingAsItStoodAtTheQuestion() async throws {
        let root = try Self.scratch(), out = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out) }
        let rows = try await Self.run(arms: ["K", "S", "S3"], root: root, out: out)
        #expect(rows.count == 6)
        func row(_ id: String, _ arm: String) throws -> [String: Any] { try #require(rows.first { ($0["id"] as? String) == id && ($0["arm"] as? String) == arm }) }
        // The typed question about a meeting that is being recorded: keywords unless the prefix is embedded.
        #expect(try row("M1-q1", "K")["mode"] as? String == "keyword")
        #expect(try row("M1-q1", "S")["mode"] as? String == "keyword", "as shipped, the meeting being recorded is not embedded")
        #expect(try row("M1-q1", "S3")["mode"] as? String == "semantic")
        #expect(try row("M1-q1", "K")["path"] as? String == "ask")
        let s3 = try #require(try row("M1-q1", "S3")["budget"] as? [String: Any])
        #expect(s3["recall"] as? Double == 1, "recruiting is about hiring: the cosine finds the line, keywords cannot")
        let k = try #require(try row("M1-q1", "K")["budget"] as? [String: Any])
        #expect(k["recall"] as? Double == 0)
        // The heard question, with the earlier session as a past meeting: the past source is ranked by meaning from S on.
        #expect(try row("M1:6:1", "K")["path"] as? String == "live" && row("M1:6:1", "K")["mode_past"] as? String == "keyword")
        #expect(try row("M1:6:1", "S")["mode_past"] as? String == "semantic")
        let gate = try #require(try row("M1:6:1", "S3")["gate"] as? [String: Any])
        #expect(gate.keys.contains("0.65") && gate.count == 8)
        let rank = try #require(try row("M1:6:1", "S3")["rank"] as? [String: Any])
        #expect((rank["hit"] as? [String: Double])?["3"] == 1)
        // No text of the transcripts is written.
        let raw = try String(contentsOf: out.appendingPathComponent("retrieval/retrieval.jsonl"), encoding: .utf8)
        #expect(!raw.contains("Berlin") && !raw.contains("hiring plan"))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("retrieval/run.json").path))
    }

    @Test func theOnDemandArmRunsTheAppsOwnCodeAndMeasuresIt() async throws {
        let root = try Self.scratch(), out = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out) }
        // A meeting too long for Apple's window, with one line about money; a typed question about it, and a heard one (which never embeds the prefix).
        let lines = (0..<70).map { i in i == 25 ? "Our finance and money matters were high this quarter" :
            "Line \(i) of the long meeting about the roadmap, the vendors and the timetable for the next quarter, item \(i), with more words to fill it up" }
        try Self.transcript("L1", lines, in: root)
        try Self.transcript("L0", Self.past, in: root)
        try Self.write([["qid": "L1-q1", "meeting": "L1", "meeting_language": "en", "question_language": "en", "question": "What is our budget spending and costs?", "category": "fact",
                         "answerable": true, "gold_segments": [26], "corpus": ["base": "base", "meeting": "L1", "upto_segment": 70]],
                        ["qid": "L0-q1", "meeting": "L0", "meeting_language": "en", "question_language": "en", "question": "What was the Berlin budget?", "category": "fact",
                         "answerable": true, "gold_segments": [2], "corpus": ["base": "base", "meeting": "L0", "upto_segment": 4]]], to: root.appendingPathComponent("w11_questions.jsonl"))
        try Self.write([["id": "L1:70:1", "condition": "A", "meeting": "L1", "language": "en", "split": "dev", "query": "What is our budget spending and costs?", "answerable": "so_far",
                         "self_segment_id": 70, "gold_segments": [26], "query_language": "en", "corpus": [["base": "base", "meeting": "L1", "upto_segment": 70]]]],
                  to: root.appendingPathComponent("w10_information.jsonl"))
        var o = LLMEvaluation.Options(sets: root, out: out)
        o.tasks = ["retrieval"]
        o.retrieval.arms = ["K", "S", "S3od"]
        o.retrieval.sets = ["w11", "w10"]
        o.searchModel = BudgetedEmbedder(limit: 500)
        try await RetrievalEvaluation.run(o, log: { _ in })
        let text = try String(contentsOf: out.appendingPathComponent("retrieval/retrieval.jsonl"), encoding: .utf8)
        let rows = text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        func row(_ id: String, _ arm: String) -> [String: Any]? { rows.first { ($0["id"] as? String) == id && ($0["arm"] as? String) == arm } }
        #expect(row("L1:70:1", "S3od") == nil, "a question heard in the meeting runs no on-demand code")
        let typed = try #require(row("L1-q1", "S3od"))
        let measured = try #require(typed["ondemand"] as? [String: Any])
        #expect((measured["embedded"] as? Int ?? 0) > 0 && measured["skipped"] == nil)
        #expect(measured["embedded"] as? Int == measured["closed"] as? Int && measured["secondEmbedded"] as? Int == 0, "the second question embeds nothing")
        #expect(typed["mode"] as? String == "semantic" && (typed["budget"] as? [String: Any])?["recall"] as? Double == 1)
        #expect(row("L1-q1", "S")?["mode"] as? String == "keyword" && (row("L1-q1", "K")?["budget"] as? [String: Any])?["recall"] as? Double == 0)
        for key in ["seconds", "cpuJoules", "peakFootprintMB", "footprintBeforeMB"] { #expect(measured[key] != nil, "\(key) is recorded") }
        // A meeting the window holds whole embeds nothing.
        let small = try #require(row("L0-q1", "S3od")?["ondemand"] as? [String: Any])
        #expect(small["skipped"] as? String == "fitsInContext" && small["embedded"] == nil)
    }

    @Test func theMmrArmAndTheLeakArmRun() async throws {
        let root = try Self.scratch(), out = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out) }
        let rows = try await Self.run(arms: ["S3MMR", "S3leak", "Tref"], root: root, out: out)
        #expect(Set(rows.compactMap { $0["arm"] as? String }) == ["S3MMR", "S3leak"], "Tref needs a translated query and the rows have none")
    }

    @Test func controlsRankAPoolWithBothSystems() async throws {
        let root = try Self.scratch(), out = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out) }
        try Self.write([["type": "pool", "context_language": "en", "passages": [["id": "p0", "text": "The cats slept all day"], ["id": "p1", "text": "The budget and the costs rose"], ["id": "p2", "text": "A car engine"]]],
                        ["type": "query", "qid": "q0", "query": "gastos del presupuesto budget", "query_language": "es", "gold_passage": "p1", "answer": "x"]],
                  to: root.appendingPathComponent("mlqa_es_to_en.jsonl"))
        var o = LLMEvaluation.Options(sets: root, out: out)
        o.tasks = ["retrieval-controls"]
        o.retrieval.controls = ["mlqa_es_to_en"]
        o.searchModel = BudgetedEmbedder(limit: 500)
        try await RetrievalEvaluation.runControls(o, log: { _ in })
        let data = try Data(contentsOf: out.appendingPathComponent("retrieval/controls.json"))
        let summary = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require(summary["mlqa_es_to_en"] as? [String: Any])
        #expect(entry["queries"] as? Int == 1)
        #expect((entry["cosine"] as? [String: Double])?["hit1"] == 1 && (entry["bm25"] as? [String: Double])?["hit1"] == 1)
    }
}
