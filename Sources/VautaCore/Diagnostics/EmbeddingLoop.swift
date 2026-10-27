// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// `Vauta embed-loop` and `Vauta llm-eval --with-embeddings`: EVALUATION ONLY. Embeds the windows of a PUBLIC transcript with the
/// search model over and over, the way indexing a library does, so the concurrency of the two MLX models (one GPU job at a time,
/// `MLXWorkGate`) can be measured: how long an embedding batch waits while a language-model job runs, and the other way round. It
/// reads one transcript file, opens no store and no network, and reports counts and timings, never text.
///
/// The purpose matters: `.document` is bulk indexing, the lowest priority of the GPU gate, so next to a minutes job it waits until the job
/// is over (that is the design: a library is indexed in the gaps); `.query` is a question's embedding, interactive priority, which must
/// wait at most one prefill chunk or one burst of tokens of a running generation. The concurrency measurement runs both.
public enum EmbeddingLoop {
    public struct Report: Codable, Sendable, Equatable {
        public var windows: Int
        public var batches: Int
        public var seconds: Double
        public var windowsPerSecond: Double
        /// Seconds from asking for a batch to having its vectors (including the wait for the GPU gate).
        public var batchMedianSeconds: Double
        public var batchP90Seconds: Double
        public var batchMaxSeconds: Double
        public var errors: Int
    }

    /// Consecutive passages joined into windows of `window` passages (a chunk of a library's document is about this long).
    static func windows(_ transcript: MinutesEvaluation.Transcript, window: Int) -> [String] {
        let texts = transcript.passages.map(\.text)
        return stride(from: 0, to: texts.count, by: max(1, window)).map { texts[$0..<min(texts.count, $0 + window)].joined(separator: " ") }
    }

    /// Embeds batches of `batch` windows, cycling through the transcript, until `until` says stop (checked between batches) or
    /// `passes` full passes are done (0 = no limit).
    public static func run(transcript: MinutesEvaluation.Transcript, store: SearchModelStore, batch: Int = 8, window: Int? = nil, passes: Int = 0,
                           purpose: EmbeddingPurpose = .document, until: @escaping @Sendable () -> Bool = { false }) async throws -> Report {
        guard case .installed = store.disk() else { throw MinutesEvaluation.Failure.modelUnavailable("the search model is not installed") }
        // A query is one passage (a question is a sentence); a document chunk is a few.
        let all = windows(transcript, window: window ?? (purpose == .query ? 1 : 4))
        guard !all.isEmpty else { throw MinutesEvaluation.Failure.noAnswer }
        let engine = SearchModelEngine(store: store)
        var durations: [Double] = []
        var windowsDone = 0, errors = 0, pass = 0, cursor = 0
        let started = Date()
        while !until(), passes == 0 || pass < passes {
            let end = min(all.count, cursor + max(1, batch))
            let texts = Array(all[cursor..<end])
            let t0 = Date()
            do {
                let vectors = try await engine.embed(texts, purpose: purpose)
                errors += vectors.filter(\.isEmpty).count
                durations.append(Date().timeIntervalSince(t0))
                windowsDone += texts.count
            } catch is CancellationError {
                break
            } catch {
                errors += texts.count
            }
            cursor = end
            if cursor >= all.count { cursor = 0; pass += 1 }
        }
        await engine.unload()
        let elapsed = Date().timeIntervalSince(started)
        let sorted = durations.sorted()
        func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        return Report(windows: windowsDone, batches: durations.count, seconds: elapsed, windowsPerSecond: elapsed > 0 ? Double(windowsDone) / elapsed : 0,
                      batchMedianSeconds: q(0.5), batchP90Seconds: q(0.9), batchMaxSeconds: sorted.last ?? 0, errors: errors)
    }
}
