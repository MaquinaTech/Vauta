// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The `links` task of `llm-eval` on an invented series: the series file, the blind labels, the pool, the replay scenarios and the
/// options need no model, no search model and no network.
@Suite("Links: the evaluation task")
struct LinksEvaluationTests {
    typealias Folder = BriefEvaluationTests.Folder

    static let lines = [
        "Ana, can you send the revised budget to the finance team?", "Yes, I will send the revised budget to the finance team on Friday.",
        "We also need to review the hiring plan for the engineering team.", "I will review the hiring plan for the engineering team.",
        "Let's keep the C-shaped shell for the launch units.", "Agreed, we keep the C-shaped shell for the launch units.",
    ]
    static let minutesA = """
        {"case": "S1a", "summary": "The team met.", "decisions": [{"text": "Keep the C-shaped shell for the launch units", "citations": [6]}],
         "tasks": [{"text": "Send the revised budget to the finance team", "owner": null, "due": null, "citations": [2]},
                   {"text": "Review the hiring plan for the engineering team", "owner": null, "due": null, "citations": [4]},
                   {"text": "Zzz qqq rank", "owner": null, "due": null, "unconfirmed": true, "citations": [1]}], "open_questions": []}
        """
    static let minutesB = """
        {"case": "S1b", "summary": "The team met again.", "decisions": [{"text": "Keep the C-shaped shell for the launch units", "citations": [6]}],
         "tasks": [{"text": "Send the budget to the finance team", "owner": null, "due": null, "citations": [2]},
                   {"text": "Review the hiring plan with the engineering team", "owner": null, "due": null, "citations": [4]}], "open_questions": []}
        """
    static let series = """
        {"clusters": [{"id": "S1", "language": "en", "split": "dev", "attendees": ["Ana López"], "meetings": [{"name": "S1a"}, {"name": "S1b"}]},
                      {"id": "S2", "language": "en", "split": "test", "meetings": [{"name": "S2a", "date": "2026-02-02T10:00:00Z"}]}]}
        """

    static func options(_ folder: Folder) throws -> (LLMEvaluation.Options, [String: BriefEvaluation.StoredMinutes]) {
        try folder.write("S1a.json", BriefEvaluationTests.transcript(lines))
        try folder.write("S1b.json", BriefEvaluationTests.transcript(lines))
        try folder.write("series.json", series)
        try folder.write("minutes_apple.jsonl", minutesA.replacingOccurrences(of: "\n", with: " ") + "\n" + minutesB.replacingOccurrences(of: "\n", with: " ") + "\n")
        var o = LLMEvaluation.Options(sets: folder.url, out: folder.url.appendingPathComponent("out"))
        o.links.series = folder.url.appendingPathComponent("series.json")
        o.links.minutes["apple"] = folder.url.appendingPathComponent("minutes_apple.jsonl")
        for sub in ["links", "pool", "sealed"] { try FileManager.default.createDirectory(at: o.out.appendingPathComponent(sub), withIntermediateDirectories: true) }
        return (o, BriefEvaluation.loadMinutes(o.links.minutes["apple"]))
    }

    @Test func theSeriesFileGivesTheClustersAndTheSplitFiltersThem() throws {
        let folder = try Folder()
        let (o, _) = try Self.options(folder)
        #expect(try LinksEvaluation.loadSeries(o.links).map(\.id) == ["S1", "S2"])
        var dev = o.links
        dev.split = "dev"
        #expect(try LinksEvaluation.loadSeries(dev).map(\.id) == ["S1"])
        // The development-only arm never reaches a test cluster, whether the split is asked for or the file mixes both.
        dev.arms = [.lk0, .ls0r]
        #expect(try LinksEvaluation.loadSeries(dev).map(\.id) == ["S1"])
        var mixed = dev
        mixed.split = nil
        #expect(throws: LinksEvaluation.Failure.self) { try LinksEvaluation.loadSeries(mixed) }
        mixed.split = "test"
        #expect(throws: LinksEvaluation.Failure.self) { try LinksEvaluation.loadSeries(mixed) }
        dev.arms = [.lk0]
        dev.series = nil
        #expect(throws: LinksEvaluation.Failure.self) { try LinksEvaluation.loadSeries(dev) }
        // Meetings with no date are a week apart; a dated one keeps its date.
        let clusters = try LinksEvaluation.loadSeries(o.links)
        #expect(LinksEvaluation.date(clusters[0], 1).timeIntervalSince(LinksEvaluation.date(clusters[0], 0)) == 7 * 86_400)
        #expect(LinksEvaluation.date(clusters[1], 0) == ISO8601DateFormatter().date(from: "2026-02-02T10:00:00Z"))
    }

    @Test func armsAreNamedAndNeedTheirModelsAndTheLabelsSayNothingAboutTheArm() {
        #expect(LinksEvaluation.Options.arms(named: ["lk0", "LS0", "ls0r"]) == [.lk0, .ls0, .ls0r])
        #expect(LinksEvaluation.Options.arms(named: ["LK0", "LSS"]) == nil, "the server arm is not run")
        var options = LinksEvaluation.Options()
        #expect(options.needsIntegratedModel() && options.needsSearchModel)
        #expect(!options.needsIntegratedModel(providers: ["apple"]), "the baseline loads the integrated model only when that backend is evaluated")
        options.arms = [.lk0, .lka]
        #expect(!options.needsIntegratedModel() && !options.needsSearchModel)
        #expect(LinksEvaluation.Arm.ls0r.devOnly && !LinksEvaluation.Arm.ls0.devOnly)
        var labels = LinksEvaluation.Labels()
        let a = labels.label(cluster: "S1", arm: .lk0, provider: "apple"), b = labels.label(cluster: "S1", arm: .ls0, provider: "apple")
        #expect(a != b && a.count == 8 && !a.lowercased().contains("lk") && labels.key[a]?["arm"] == "LK0")
        #expect("A\tB\nC".contains("\t") && !LinksEvaluation.cell("A\tB\nC").contains("\t") && !LinksEvaluation.cell("A\tB\nC").contains("\n"))
        #expect(LinksEvaluation.p90([]) == 0 && LinksEvaluation.p90(Array(1...10)) == 9)
    }

    @Test func theClusterIsSeededInOrderWithTheSeriesAndTheMinutes() async throws {
        let folder = try Folder()
        let (o, minutes) = try Self.options(folder)
        let cluster = try LinksEvaluation.loadSeries(o.links)[0]
        let store = try MeetingStore(directory: folder.url.appendingPathComponent("s"), keyStore: MemoryKeyStore())
        let seeded = try await LinksEvaluation.seedCluster(cluster, minutes: minutes, sets: o.sets, directory: folder.url, store: store)
        #expect(seeded.ids.count == 2 && seeded.missing.isEmpty && seeded.names[seeded.ids[1]] == "S1b")
        #expect(try await store.seriesID(of: seeded.ids[0]) == store.seriesID(of: seeded.ids[1]))
        #expect(try await store.tasks(seeded.ids[0]).count == 3)
        #expect(try await store.decisions(seeded.ids[1]).count == 1)
        let first = try #require(try await store.meeting(seeded.ids[0])), second = try #require(try await store.meeting(seeded.ids[1]))
        #expect(second.startedAt.timeIntervalSince(first.startedAt) == 7 * 86_400)
        // A meeting without a transcript is reported, not invented.
        var gap = cluster
        gap = LinksEvaluation.Cluster.testCopy(gap, names: ["S1a", "nope"])
        let store2 = try MeetingStore(directory: folder.url.appendingPathComponent("s2"), keyStore: MemoryKeyStore())
        let partial = try await LinksEvaluation.seedCluster(gap, minutes: minutes, sets: o.sets, directory: folder.url, store: store2)
        #expect(partial.ids.count == 1 && partial.missing == ["nope"])
    }

    @Test func thePoolHasEverySameSeriesPairWithBandsAndNoArmName() async throws {
        let folder = try Folder()
        let (o, minutes) = try Self.options(folder)
        let cluster = try LinksEvaluation.loadSeries(o.links)[0]
        let store = try MeetingStore(directory: folder.url.appendingPathComponent("s"), keyStore: MemoryKeyStore())
        let seeded = try await LinksEvaluation.seedCluster(cluster, minutes: minutes, sets: o.sets, directory: folder.url, store: store)
        let rows = try await LinksEvaluation.writePool(seeded: seeded, cluster: cluster, provider: "apple", policy: LinkPolicy(), out: o.out)
        let text = try String(contentsOf: o.out.appendingPathComponent("pool/S1.apple.tsv"), encoding: .utf8)
        #expect(rows == text.split(separator: "\n").count - 1 && rows >= 4)
        #expect(text.contains("Send the budget to the finance team\tS1a\tSend the revised budget to the finance team"))
        #expect(text.contains("\tna\t"), "without the search model the cosine is not known")
        #expect(!text.contains("LK0") && !text.contains("LS0"))
        #expect(LinksEvaluation.band(0.85) == ">=0.80" && LinksEvaluation.band(0.65) == "0.60-0.72" && LinksEvaluation.band(0.3) == "<0.60" && LinksEvaluation.band(nil) == "na")
        #expect(LinksEvaluation.jaccardBand(0.6) == ">=0.5" && LinksEvaluation.jaccardBand(0) == "0")
    }

    @Test func theReplayScenariosHoldOnAnInventedSeries() async throws {
        let folder = try Folder()
        let (o, minutes) = try Self.options(folder)
        let cluster = try LinksEvaluation.loadSeries(o.links)[0]
        let providers = EvaluationProviders(.apple)
        let report = try await LinksEvaluation.replay(cluster: cluster, minutes: minutes, options: o, directory: folder.url, providers: providers)
        #expect(report.failures == 0, "\(report.detail)")
        #expect(report.detail["check_deterministic"] == "ok" && report.detail["check_rankedOutNeverLinked"] == "ok")
        #expect(report.detail["check_dismissalSurvivesRewrite"] == "ok" && report.detail["check_confirmationSurvivesRewrite"] == "ok")
        #expect(report.detail["check_rewriteNamesLaterMeetings"] == "ok" && report.detail["check_nothingWhileRecording"] == "ok")
        #expect(Int(report.detail["suggestions"] ?? "0") ?? 0 >= 2)
    }

    @Test func theBaselineAnswerIsReadLeniently() {
        let pairs = LinksEvaluation.parseBaseline("Sure! {\"links\":[{\"item\":\"N1\",\"earlier\":\"e2\",\"relation\":\"Same\"},{\"item\":\"n2\",\"earlier\":\"e1\",\"relation\":\"banana\"},{\"item\":\"n3\"}]} done")
        #expect(pairs.count == 1 && pairs[0].item == "n1" && pairs[0].earlier == "e2" && pairs[0].relation == "same")
        #expect(LinksEvaluation.parseBaseline("nothing").isEmpty)
    }

    @Test func theFixturesAreOnlyHashed() throws {
        let folder = try Folder()
        try folder.write("S1b.links.json", #"{"meeting": "S1b", "secret": "closing words"}"#)
        var options = LinksEvaluation.Options()
        options.fixtures = folder.url
        let manifest = LinksEvaluation.fixtureManifest(options)
        #expect(manifest.hasSuffix("  S1b.links.json\n") && manifest.split(separator: " ").first?.count == 64 && !manifest.contains("closing"))
    }

    @Test func theOptionsAreKnownToTheCommandLine() {
        for name in ["--links-arms", "--links-series", "--links-fixtures", "--links-split", "--links-minutes-apple", "--links-minutes-integrated"] {
            #expect(CommandInvocation.valueOptions.contains(name), "\(name)")
        }
    }
}

extension LinksEvaluation.Cluster {
    /// A cluster with other meeting names (tests).
    static func testCopy(_ c: LinksEvaluation.Cluster, names: [String]) -> LinksEvaluation.Cluster {
        let json = #"{"id": "\#(c.id)", "language": "en", "meetings": [\#(names.map { #"{"name": "\#($0)"}"# }.joined(separator: ","))]}"#
        return try! JSONDecoder().decode(LinksEvaluation.Cluster.self, from: Data(json.utf8))
    }
}
