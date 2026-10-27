// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Compression
import Foundation

/// The controls of the retrieval evaluation: public retrieval sets (MIRACL dev rerank pools in Spanish, English and Japanese; MLQA
/// Spanish-English and English-Spanish) ranked with the search model's embedder and with BM25 over `TextKeys` tokens, to check that the
/// harness reproduces the model's known behaviour (BENCHMARKS.md) before the meeting sets are read. Each query ranks its own pool of
/// candidates (MIRACL: about 100 per query; MLQA: every distinct context of the file), so the numbers are not those of a full-corpus run.
extension RetrievalEvaluation {
    /// Okapi BM25 (k1 1.2, b 0.75) of `query` terms over `documents`, the pool being the corpus.
    public static func bm25(query: [String], documents: [[String]], k1: Double = 1.2, b: Double = 0.75) -> [Double] {
        guard !documents.isEmpty else { return [] }
        let average = max(1, Double(documents.reduce(0) { $0 + $1.count }) / Double(documents.count))
        var df: [String: Int] = [:]
        for d in documents { for t in Set(d) { df[t, default: 0] += 1 } }
        let n = Double(documents.count)
        return documents.map { d in
            var counts: [String: Int] = [:]
            for t in d { counts[t, default: 0] += 1 }
            return Set(query).reduce(0.0) { sum, term in
                guard let f = counts[term], let n_t = df[term] else { return sum }
                let idf = log(1 + (n - Double(n_t) + 0.5) / (Double(n_t) + 0.5))
                return sum + idf * Double(f) * (k1 + 1) / (Double(f) + k1 * (1 - b + b * Double(d.count) / average))
            }
        }
    }

    /// Reciprocal rank fusion (k = 60) of rankings given as scores (higher is better): the fused score of each item.
    public static func rrf(_ scores: [[Double]], k: Double = 60) -> [Double] {
        guard let n = scores.first?.count else { return [] }
        var fused = [Double](repeating: 0, count: n)
        for s in scores {
            let order = s.indices.sorted { s[$0] == s[$1] ? $0 < $1 : s[$0] > s[$1] }
            for (rank, i) in order.enumerated() { fused[i] += 1 / (k + Double(rank + 1)) }
        }
        return fused
    }

    /// Binary-relevance metrics of a ranking: nDCG@10, reciprocal rank@10, recall@3 and hit@1.
    public static func controlMetrics(scores: [Double], relevant: Set<Int>) -> (ndcg10: Double, mrr10: Double, recall3: Double, hit1: Double)? {
        guard !relevant.isEmpty else { return nil }
        let order = scores.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        var dcg = 0.0, mrr = 0.0
        for (rank, i) in order.prefix(10).enumerated() where relevant.contains(i) {
            dcg += 1 / log2(Double(rank) + 2)
            if mrr == 0 { mrr = 1 / Double(rank + 1) }
        }
        let ideal = (0..<min(10, relevant.count)).reduce(0.0) { $0 + 1 / log2(Double($1) + 2) }
        let top3 = Set(order.prefix(3))
        return (dcg / ideal, mrr, Double(top3.intersection(relevant).count) / Double(relevant.count), relevant.contains(order[0]) ? 1 : 0)
    }

    private static func terms(_ text: String, language: String) -> [String] {
        TextKeys.tokens(text, profile: LanguageProfile(locale: Locale(identifier: language))).map(\.norm)
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Double { QuestionEvidenceGate.cosine(a, b) }

    private struct ControlQuery {
        let id: String
        let text: String
        let language: String
        let pool: [String]
        let relevant: Set<Int>
    }

    private static func readLines(_ url: URL) throws -> [[String: Any]] {
        guard var data = FileManager.default.contents(atPath: url.path) else { throw DataError.unreadable(url.path) }
        if url.pathExtension == "gz" { data = try gunzip(data) }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    /// The payload of a gzip file (the header is skipped; the 8 byte trailer is not part of the deflate stream).
    private static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw DataError.unreadable("not a gzip file") }
        let end = bytes.count - 8   // the deflate stream stops before the trailer
        var offset = 10
        let flags = bytes[3]
        // Every read of the header is checked against the end of the file: a truncated file is an error, not a trap.
        func skipZeroTerminated() throws {
            while offset < end, bytes[offset] != 0 { offset += 1 }
            offset += 1
            guard offset <= end else { throw DataError.unreadable("truncated gzip header") }
        }
        if flags & 4 != 0 {
            guard offset + 2 <= end else { throw DataError.unreadable("truncated gzip header") }
            offset += 2 + Int(bytes[offset]) + (Int(bytes[offset + 1]) << 8)
        }
        if flags & 8 != 0 { try skipZeroTerminated() }
        if flags & 16 != 0 { try skipZeroTerminated() }
        if flags & 2 != 0 { offset += 2 }
        guard offset < end else { throw DataError.unreadable("truncated gzip header") }
        let payload = Array(bytes[offset..<end])
        let capacity = max(1 << 20, data.count * 12)
        var out = Data()
        var size = capacity
        while true {
            var buffer = [UInt8](repeating: 0, count: size)
            let n = compression_decode_buffer(&buffer, size, payload, payload.count, nil, COMPRESSION_ZLIB)
            // 0 is a decode error (a corrupt stream never gets better with a larger buffer); `size` means the output was cut off.
            guard n > 0 else { throw DataError.unreadable("corrupt gzip stream") }
            if n < size { out = Data(buffer[0..<n]); break }
            guard size < (1 << 30) else { throw DataError.unreadable("gzip too large") }
            size *= 4
        }
        return out
    }

    private static func controlQueries(_ name: String, root: URL, limit: Int?) throws -> [ControlQuery] {
        var out: [ControlQuery] = []
        if name.hasPrefix("miracl_") {
            // The archive keeps MIRACL gzipped; a plain file next to it wins.
            let plain = root.appendingPathComponent(name + ".jsonl")
            for row in try readLines(FileManager.default.fileExists(atPath: plain.path) ? plain : root.appendingPathComponent(name + ".jsonl.gz")) {
                guard let id = row["qid"] as? String, let text = row["query"] as? String, let language = row["language"] as? String,
                      let candidates = row["candidates"] as? [[String: Any]] else { continue }
                let relevant = Set(candidates.enumerated().compactMap { i, c in ((c["relevant"] as? Bool) ?? ((c["relevant"] as? String)?.lowercased() == "true")) ? i : nil })
                let pool = candidates.map { c in [c["title"] as? String, c["text"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
                out.append(ControlQuery(id: id, text: text, language: language, pool: pool, relevant: relevant))
            }
        } else {
            let rows = try readLines(root.appendingPathComponent(name + ".jsonl"))
            let poolRow = rows.first { ($0["type"] as? String) == "pool" }
            let passages = (poolRow?["passages"] as? [[String: Any]]) ?? []
            // A passage id that appears twice keeps its first position.
            let index = Dictionary(passages.enumerated().compactMap { i, p in (p["id"] as? String).map { ($0, i) } }, uniquingKeysWith: { first, _ in first })
            let pool = passages.map { $0["text"] as? String ?? "" }
            for row in rows where (row["type"] as? String) == "query" {
                guard let id = row["qid"] as? String, let text = row["query"] as? String, let language = row["query_language"] as? String,
                      let gold = (row["gold_passage"] as? String).flatMap({ index[$0] }) else { continue }
                out.append(ControlQuery(id: id, text: text, language: language, pool: pool, relevant: [gold]))
            }
        }
        return limit.map { Array(out.prefix($0)) } ?? out
    }

    public static func runControls(_ o: LLMEvaluation.Options, log: @escaping @Sendable (String) -> Void) async throws {
        guard let embedder = o.searchModel else { throw DataError.unreadable("retrieval-controls needs --search-model") }
        let directory = o.out.appendingPathComponent("retrieval", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rows = directory.appendingPathComponent("controls.jsonl")
        FileManager.default.createFile(atPath: rows.path, contents: nil)
        var summary: [String: Any] = [:]
        let started = Date()
        for name in o.retrieval.controls {
            let t0 = Date()
            let queries = try controlQueries(name, root: o.sets, limit: o.retrieval.maxQueries)
            var sums: [String: [Double]] = [:]
            var counted = 0
            for q in queries {
                let queryVector = try await embedder.embed([q.text], purpose: .query).vectors[0]
                let vectors = try await embedder.embed(q.pool, purpose: .document).vectors
                let cosine = vectors.map { dot(queryVector, $0) }
                let bm = bm25(query: terms(q.text, language: q.language), documents: q.pool.map { terms($0, language: q.language) })
                let systems: [(String, [Double])] = [("bm25", bm), ("cosine", cosine), ("rrf", rrf([bm, cosine]))]
                guard !q.relevant.isEmpty else { continue }
                counted += 1
                for (system, scores) in systems {
                    guard let m = controlMetrics(scores: scores, relevant: q.relevant) else { continue }
                    sums[system, default: [0, 0, 0, 0]] = zip(sums[system] ?? [0, 0, 0, 0], [m.ndcg10, m.mrr10, m.recall3, m.hit1]).map(+)
                    let row: [String: Any] = ["control": name, "qid": q.id, "system": system, "ndcg10": m.ndcg10, "mrr10": m.mrr10, "recall3": m.recall3, "hit1": m.hit1,
                                              "pool": q.pool.count, "relevant": q.relevant.count]
                    if let d = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) { LLMEvaluation.appendLine(d, to: rows) }
                }
            }
            var entry: [String: Any] = ["queries": counted, "seconds": Date().timeIntervalSince(t0).rounded(), "load1": LLMEvaluation.load()[0]]
            for (system, s) in sums where counted > 0 {
                entry[system] = ["ndcg10": s[0] / Double(counted), "mrr10": s[1] / Double(counted), "recall3": s[2] / Double(counted), "hit1": s[3] / Double(counted)]
            }
            summary[name] = entry
            log("control \(name): \(counted) queries in \(Int(Date().timeIntervalSince(t0))) s")
        }
        summary["seconds"] = Date().timeIntervalSince(started).rounded()
        if let model = embedder as? EvaluationSearchModel { summary["embeddingCache"] = ["hits": model.cacheStatistics.hits, "misses": model.cacheStatistics.misses] }
        try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("controls.json"))
    }
}
