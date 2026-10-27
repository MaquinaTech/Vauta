// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// `llm-eval --tasks links` (Part B of the post-meeting actions): EVALUATION ONLY. Runs the app's own link code over the meetings of
/// public series (the transcripts of `--sets` and the stored minutes of the minutes runs) in a throwaway encrypted store, through the
/// real job queue, and writes the pairs it would show and the counts. It never contacts a model server, never writes audio and never
/// touches Reminders, Calendar or a person's data.
///
/// Arms:
/// - `LK0` keywords, `LS0` the search model's vectors, both with the deterministic difference rules and no model;
/// - `LKA` / `LSA` the same plus Apple's model check; `LKG` / `LSG` the same plus the integrated model's check;
/// - `LBL` the backend lists repeats and changes itself from the target's items and the earlier minutes (no candidates, no verifier);
/// - `LS0R` (development only) the vector arm with the items the ranking left out included: the recall that rule costs;
/// - `POOL` not an arm: every same-series pair of eligible items with its cosine and keyword bands, without any arm name, from which
///   the gold session draws its stratified sample;
/// - `RP` the deterministic replay scenarios (dismissals and confirmations across a rewrite, a rewrite of an earlier meeting, ranked-out
///   items, determinism, no work while recording).
///
/// The arms run on the minutes of their backend: `LK0`, `LS0`, `LS0R`, `LBL`, `POOL` and `RP` for every provider given by `--providers`,
/// `LKA` and `LSA` on Apple's minutes, `LKG` and `LSG` on the integrated model's. `showsChanges` is on for every arm so the false-positive
/// rate of "different" suggestions can be judged, whatever `LinksRelease` ships.
///
/// Outputs carry blind labels, never arm names: `links/<cluster>.<label>.tsv`; `pool/<cluster>.<provider>.tsv`; `sealed/key.json` maps the
/// labels to arms and its SHA-256 is written next to it. `traces.jsonl` has counts and timings only, `replay.jsonl` the replay counts.
public enum LinksEvaluation {
    public enum Arm: String, Sendable, CaseIterable {
        case lk0 = "LK0", ls0 = "LS0", lka = "LKA", lsa = "LSA", lkg = "LKG", lsg = "LSG", lbl = "LBL", ls0r = "LS0R", pool = "POOL", rp = "RP"

        /// The search model's vectors drive the candidates.
        var semantic: Bool { [.ls0, .lsa, .lsg, .ls0r, .pool].contains(self) }
        /// The model that checks the pairs (and whose minutes the arm reads).
        var modelProvider: String? {
            switch self {
            case .lka, .lsa: "apple"
            case .lkg, .lsg: "integrated"
            default: nil
            }
        }
        var checks: Bool { modelProvider != nil }
        var usesModel: Bool { checks || self == .lbl }
        /// A development-only arm: it is never part of a test run.
        var devOnly: Bool { self == .ls0r }
    }

    public struct Options: Sendable {
        /// The arms to run, in this order (interleaved per cluster by `LLMEvaluation.order`).
        public var arms: [Arm] = [.lk0, .ls0, .lka, .lsa, .lkg, .lsg, .lbl, .pool, .rp]
        /// The clusters: `{"clusters":[{"id","language","split","attendees","meetings":[{"name","date"}]}]}`.
        public var series: URL?
        /// A folder with one `<meeting>.links.json` per target (sealed fixtures: only their hashes are used here).
        public var fixtures: URL?
        /// Stored minutes per provider ("apple", "integrated"): the `minutes_<provider>.jsonl` of the minutes runs.
        public var minutes: [String: URL] = [:]
        /// Only clusters of this split ("dev" or "test").
        public var split: String?
        public init() {}

        public static func arms(named names: [String]) -> [Arm]? {
            let found = names.map { name in Arm.allCases.first { $0.rawValue == name.uppercased() } }
            return found.contains { $0 == nil } ? nil : found.compactMap { $0 }
        }

        /// Whether any chosen arm needs the integrated model loaded: the baseline needs it only when the integrated backend is evaluated at all.
        public func needsIntegratedModel(providers: [String] = ["apple", "integrated"]) -> Bool {
            providers.contains("integrated") && arms.contains { $0.modelProvider == "integrated" || $0 == .lbl }
        }
        public var needsSearchModel: Bool { arms.contains { $0.semantic } }
    }

    // MARK: Series

    public struct Cluster: Decodable, Sendable {
        public struct Meeting: Decodable, Sendable { public let name: String; public let date: String? }
        public let id: String
        public let language: String?
        public let split: String?
        public let attendees: [String]?
        public let meetings: [Meeting]
    }

    struct SeriesFile: Decodable { let clusters: [Cluster] }

    public enum Failure: Error, CustomStringConvertible {
        case noSeries, unreadable(String), needsSearchModel(String), devOnlyArm(String)
        public var description: String {
            switch self {
            case .noSeries: "no series: --links-series <series.json>"
            case .unreadable(let name): "the file \(name) cannot be read"
            case .needsSearchModel(let arm): "the arm \(arm) needs --search-model"
            case .devOnlyArm(let arm): "the arm \(arm) is for the development split only; the test split is read once"
            }
        }
    }

    public static func loadSeries(_ o: Options) throws -> [Cluster] {
        guard let url = o.series else { throw Failure.noSeries }
        guard let data = FileManager.default.contents(atPath: url.path), let file = try? JSONDecoder().decode(SeriesFile.self, from: data) else { throw Failure.unreadable(url.lastPathComponent) }
        let clusters = file.clusters.filter { o.split == nil || $0.split == o.split }
        guard !clusters.isEmpty else { throw Failure.noSeries }
        // A development-only arm never touches a test cluster: the test split is reported once.
        if let arm = o.arms.first(where: \.devOnly), o.split == "test" || clusters.contains(where: { $0.split == "test" }) { throw Failure.devOnlyArm(arm.rawValue) }
        return clusters
    }

    /// The hashes of the sealed fixtures, written next to the results; their words are not read.
    static func fixtureManifest(_ o: Options) -> String {
        guard let folder = o.fixtures else { return "" }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".links.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { file in FileManager.default.contents(atPath: file.path).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() + "  " + file.lastPathComponent } }
            .joined(separator: "\n") + "\n"
    }

    /// The date of a meeting: the series file's, else a week after the cluster's previous one (the AMI recordings carry no dates).
    static func date(_ cluster: Cluster, _ index: Int) -> Date {
        if let text = cluster.meetings[index].date, let date = ISO8601DateFormatter().date(from: text) { return date }
        return Date(timeIntervalSince1970: 1_767_600_000).addingTimeInterval(Double(index) * 7 * 86_400)   // Monday 2026-01-05 08:00 UTC
    }

    static func fixture(_ cluster: Cluster, _ index: Int, date: Date) -> ActionsEvaluation.Fixture {
        let names = cluster.attendees ?? []
        return ActionsEvaluation.Fixture(meeting: cluster.meetings[index].name, startedAt: ISO8601DateFormatter().string(from: date), timeZone: "UTC",
                                         attendees: names.map { .init(name: $0, email: nil) }, you: nil, speakers: nil, closing: nil, existingReminders: nil)
    }

    // MARK: Blind labels

    struct Labels {
        let salt = UUID().uuidString
        var key: [String: [String: String]] = [:]

        mutating func label(cluster: String, arm: Arm, provider: String) -> String {
            let digest = SHA256.hash(data: Data("\(salt)|\(cluster)|\(arm.rawValue)|\(provider)".utf8)).map { String(format: "%02x", $0) }.joined()
            let label = String(digest.prefix(8))
            key[label] = ["cluster": cluster, "arm": arm.rawValue, "provider": provider]
            return label
        }
    }

    // MARK: Text

    /// One cell of a TSV: tabs and line breaks become spaces.
    static func cell(_ text: String) -> String { text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }

    static func p90(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
    }
}
