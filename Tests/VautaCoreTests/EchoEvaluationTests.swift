// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `llm-eval --tasks echo`: the simulated echoes are the same in every run, and the sweep scores the detector on them.
@Suite("Evaluation: the speakers' echo sweep")
struct EchoEvaluationTests {
    private static let topics = ["the supplier confirmed the new shell material for the pilot",
                                 "we will order two hundred units in April after the review",
                                 "the budget for the remote control prototype is still open",
                                 "marketing wants a younger look with brighter colours on the case",
                                 "the battery should last at least two years in normal use"]

    /// One public-looking meeting: two participants taking turns, 25 lines each, two seconds apart.
    private func meeting(at root: URL) throws -> URL {
        let sets = root.appendingPathComponent("sets", isDirectory: true)
        try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
        let passages = (0..<50).map { i -> [String: Any] in
            let start = Double(i) * 6
            return ["id": i + 1, "text": "\(Self.topics[i % 5]) number \(i)", "start": start, "end": start + 4, "speaker": "Speaker \(i % 2 + 1)"]
        }
        try JSONSerialization.data(withJSONObject: ["passages": passages, "meeting": "m1", "language": "en"]).write(to: sets.appendingPathComponent("m1.json"))
        return sets
    }

    @Test func theEchoesAreTheSameInEveryRun() {
        let others = (0..<10).map { EchoDetection.Line(id: Int64($0), channel: .others, start: Double($0) * 6, end: Double($0) * 6 + 4, text: Self.topics[$0 % 5]) }
        func echoes() -> [EchoDetection.Line] {
            var rng = EchoEvaluation.Generator(seed: 7 ^ EchoEvaluation.fnv("m1"))
            return EchoEvaluation.simulatedEchoes(of: others, avoiding: [], rate: 0.2, delay: 0.4, vocabulary: ["alpha", "beta"], rng: &rng)
        }
        let first = echoes()
        #expect(first == echoes() && !first.isEmpty)
        #expect(first.allSatisfy { $0.channel == .me && $0.id >= 1_000_000_000 })
        #expect(abs(first[0].start - (others[0].start + 0.4)) <= EchoEvaluation.jitter, "heard later")
        // An echo that would fall on the participant's own speech is left out.
        var rng = EchoEvaluation.Generator(seed: 1)
        let own = [EchoDetection.Line(id: 99, channel: .me, start: 0, end: 60, text: "I am talking the whole time")]
        #expect(EchoEvaluation.simulatedEchoes(of: others, avoiding: own, rate: 0.1, delay: 0.15, vocabulary: [], rng: &rng).isEmpty)
    }

    @Test func theSweepScoresEverySettingAndFindsTheEchoes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-echo-sweep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var o = LLMEvaluation.Options(sets: try meeting(at: root), out: root.appendingPathComponent("out", isDirectory: true))
        o.tasks = ["echo"]
        let log = Lines()
        try await LLMEvaluation.run(o, store: LanguageModelStore(applicationSupport: root), log: { log.append($0) })
        let rows = try String(contentsOf: o.out.appendingPathComponent("echo/sweep.tsv"), encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 1 + 4 * 4 * 3 * 3 * 5 && rows[0].hasPrefix("words\tpairs\tcovered\tmin_words\tmax_lead\trecall"))
        #expect(log.all.contains { $0.hasPrefix("echo: 1 meetings, 18 replays and 4 with the far side's echo") }, "\(log.all)")
        let release = try #require(log.all.first { $0.hasPrefix("echo: release ") })
        // Lines that never overlap the other participant: only the echoes can be marked, and most of them are.
        #expect(release.contains("own marked 0 of 450"), "\(release)")
        let recall = try #require(release.firstMatch(of: #/recall ([0-9.]+) /#).flatMap { Double($0.1) })
        #expect(recall > 0.7, "\(release)")
        // The far side sends every line back 0.25 or 0.5 s later: without a limit on the lead most of them would be marked.
        func farMarked(lead: String) throws -> Int {
            let row = try #require(rows.map { $0.split(separator: "\t").map(String.init) }.first { $0.prefix(5) == ["0.6", "0.3", "0.6", "4", lead] })
            return try #require(Int(row[11]))
        }
        let unlimited = try farMarked(lead: "inf"), limited = try farMarked(lead: "0.15")
        #expect(unlimited > 50 && limited < unlimited / 2, "\(limited) of \(unlimited)")

        // The far side's echo of the participant, judged in Others: most are found, and the other participant's lines (which the
        // participant's speakers echo in the other replays) are not.
        let far = try String(contentsOf: o.out.appendingPathComponent("echo/far_sweep.tsv"), encoding: .utf8).split(separator: "\n")
        #expect(far.count == 1 + 3 * 3 * 3 * 3 * 4 && far[0].hasPrefix("words\tpairs\tcovered\tmin_words\tmin_lag\trecall"))
        let farRelease = try #require(log.all.first { $0.hasPrefix("echo far: release ") })
        let farRecall = try #require(farRelease.firstMatch(of: #/recall ([0-9.]+) /#).flatMap { Double($0.1) })
        #expect(farRecall > 0.7 && farRelease.contains("others marked 0 of"), "\(farRelease)")
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}
