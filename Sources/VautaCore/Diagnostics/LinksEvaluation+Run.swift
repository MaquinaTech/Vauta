// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
internal import VautaMLX

/// The run of `llm-eval --tasks links`: one throwaway store per cluster, arm and provider, seeded meeting by meeting (the transcript and
/// the stored minutes), the link passes driven through the real job queue after each, and the pairs written under a blind label.
extension LinksEvaluation {
    static func run(_ o: LLMEvaluation.Options, store languageStore: LanguageModelStore, engine: LanguageModelEngine, write: (LLMEvaluation.Trace) -> Void) async throws {
        let options = o.links
        let clusters = try loadSeries(options)
        let out = o.out
        for folder in ["links", "pool", "sealed"] { try FileManager.default.createDirectory(at: out.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let manifest = fixtureManifest(options)
        if !manifest.isEmpty { try manifest.write(to: out.appendingPathComponent("fixtures.sha256"), atomically: true, encoding: .utf8) }
        let minutes = ["apple": BriefEvaluation.loadMinutes(options.minutes["apple"]), "integrated": BriefEvaluation.loadMinutes(options.minutes["integrated"])]
        for arm in options.arms where arm.semantic && o.searchModel == nil { throw Failure.needsSearchModel(arm.rawValue) }
        var labels = Labels()
        var pair = 0
        for cluster in clusters {
            let (waited, _) = await LLMEvaluation.waitForQuiet(o)
            // The (arm, provider) runs of this cluster: an arm on the minutes of its own backend, the others on every provider asked for.
            var runs: [(arm: Arm, provider: String)] = []
            for arm in options.arms {
                if let provider = arm.modelProvider {
                    if o.providers.contains(provider), minutes[provider]?.isEmpty == false { runs.append((arm, provider)) }
                } else {
                    for provider in o.providers where minutes[provider]?.isEmpty == false { runs.append((arm, provider)) }
                }
            }
            let sequence = LLMEvaluation.order(pair, runs.map { "\($0.arm.rawValue)/\($0.provider)" })
            for entry in sequence {
                guard let run = runs.first(where: { "\($0.arm.rawValue)/\($0.provider)" == entry }) else { continue }
                // A model is loaded only for the arms that call one; the others hand Apple's model object to the service, which never uses it.
                let model: EvaluationModel = run.arm.usesModel ? LLMEvaluation.model(run.arm.modelProvider ?? run.provider, store: languageStore, greedy: o.greedy, engine: engine) : .apple
                let label = labels.label(cluster: cluster.id, arm: run.arm, provider: run.provider)
                let trace = await LLMEvaluation.measure(task: "links", provider: run.provider, item: "\(cluster.id).\(label)", pair: pair,
                                                        order: sequence.first == entry ? "first" : "later", model: model, waited: waited, options: o) {
                    try await runArm(run.arm, provider: run.provider, cluster: cluster, label: label, minutes: minutes[run.provider] ?? [:], model: model, options: o)
                }
                write(trace)
            }
            pair += 1
        }
        // The key is sealed: written once, hashed, and not read until the grades are.
        let key = try JSONSerialization.data(withJSONObject: labels.key, options: [.sortedKeys, .prettyPrinted])
        try key.write(to: out.appendingPathComponent("sealed/key.json"))
        try (SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() + "  key.json\n").write(to: out.appendingPathComponent("sealed/key.sha256"), atomically: true, encoding: .utf8)
    }

    /// A cluster's meetings in a store, oldest first, with the earlier ones' names by id.
    struct SeededCluster {
        let store: MeetingStore
        var ids: [Int64] = []
        var names: [Int64: String] = [:]
        var missing: [String] = []
    }

    static func seedCluster(_ cluster: Cluster, minutes: [String: BriefEvaluation.StoredMinutes], sets: URL, directory: URL, store: MeetingStore,
                            afterEach: ((Int64) async -> Void)? = nil) async throws -> SeededCluster {
        var seeded = SeededCluster(store: store)
        let seriesID = try await store.saveSeries(MeetingSeries(titlePattern: cluster.id))
        for (index, meeting) in cluster.meetings.enumerated() {
            guard let data = FileManager.default.contents(atPath: sets.appendingPathComponent(meeting.name + ".json").path),
                  let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data), !transcript.passages.isEmpty else {
                seeded.missing.append(meeting.name)
                continue
            }
            let start = date(cluster, index)
            let made = try await ActionsEvaluation.seed(name: cluster.language == "es" ? "es_" + meeting.name : meeting.name, transcript: transcript,
                                                        fixture: fixture(cluster, index, date: start), minutes: minutes[meeting.name], directory: directory, into: store, startedAt: start)
            try await store.setSeries(seriesID, of: made.meetingID)
            seeded.ids.append(made.meetingID)
            seeded.names[made.meetingID] = meeting.name
            if let afterEach { await afterEach(made.meetingID) }
        }
        return seeded
    }

    static func runArm(_ arm: Arm, provider: String, cluster: Cluster, label: String, minutes: [String: BriefEvaluation.StoredMinutes], model: EvaluationModel,
                       options o: LLMEvaluation.Options) async throws -> (calls: [EvaluationCall], detail: [String: String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-links-eval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var detail: [String: String] = ["arm": label, "cluster": cluster.id, "meetings": "\(cluster.meetings.count)", "language": cluster.language ?? "en"]

        // Every arm but the replay reads the cluster through a service with the arm's policy and providers.
        var policy = LinkPolicy()
        policy.showsChanges = true
        policy.modelCheck = arm.checks
        policy.modelCheckNeedsLoadedModel = false
        policy.includesRankedOut = arm == .ls0r
        let providers = EvaluationProviders(model, searchModel: arm.semantic ? o.searchModel : nil)

        if arm == .rp {
            let report = try await replay(cluster: cluster, minutes: minutes, options: o, directory: directory, providers: providers)
            detail.merge(report.detail) { _, new in new }
            if let d = try? JSONSerialization.data(withJSONObject: report.detail.merging(["cluster": cluster.id, "provider": provider]) { _, new in new }, options: [.sortedKeys]) {
                LLMEvaluation.appendLine(d, to: o.out.appendingPathComponent("replay.jsonl"))
            }
            if report.failures > 0 { throw ReplayFailure(failures: report.failures, detail: report.detail) }
            return ([], detail)
        }

        let before = providers.chatModel.records.count
        let clusterStore = try MeetingStore(directory: directory.appendingPathComponent("store"), keyStore: MemoryKeyStore())
        let llm = LLMService(store: clusterStore, providers: providers, searchDefaults: EvaluationDefaults.suite)   // never .standard
        await llm.forgetSearchModelCoverage()
        await llm.setLinkPolicy(policy)

        if arm == .lbl {
            let seeded = try await seedCluster(cluster, minutes: minutes, sets: o.sets, directory: directory, store: clusterStore)
            let lines = try await baseline(seeded: seeded, cluster: cluster, providers: providers, label: label, out: o.out)
            detail["pairs"] = "\(lines)"
            detail["missing"] = seeded.missing.joined(separator: ",")
            return (Array(providers.chatModel.records.dropFirst(before)), detail)
        }

        let seeded = try await seedCluster(cluster, minutes: minutes, sets: o.sets, directory: directory, store: clusterStore) { id in
            _ = await llm.linksAfterMinutesForEvaluation(id)
        }
        detail["missing"] = seeded.missing.joined(separator: ",")
        let traces = await llm.linkTraces
        detail["passes"] = "\(traces.count)"
        detail["passMsP90"] = "\(p90(traces.map(\.milliseconds)))"
        detail["modelCalls"] = "\(traces.reduce(0) { $0 + $1.modelCalls })"
        detail["vectorPasses"] = "\(traces.filter { $0.pass != .keyword }.count)"
        detail["duringRecording"] = "\(traces.filter(\.duringRecording).count)"

        if arm == .pool {
            detail["poolRows"] = "\(try await writePool(seeded: seeded, cluster: cluster, provider: provider, policy: policy, out: o.out))"
            return ([], detail)
        }
        var shown = 0
        var byMethod: [String: Int] = [:], byRelation: [String: Int] = [:]
        // The blind file has no column that tells the arm family (method, score); those go to the sealed copy, one directory away.
        var rows: [String] = ["meeting\tkind\trelation\tnewer\tearlier_meeting\tearlier\tevidence"]
        var sealed: [String] = ["meeting\tkind\tnewer\tearlier\tmethod\tscore"]
        for (index, id) in seeded.ids.enumerated() where index > 0 {
            let linkRows = try await seeded.store.linkRows(ofMeeting: id)
            let texts = try await itemTexts(seeded.store, meeting: id)
            for (key, row) in linkRows.sorted(by: { ($0.key.kind.rawValue, $0.key.itemID) < ($1.key.kind.rawValue, $1.key.itemID) }) {
                shown += 1
                byMethod[row.link.method.rawValue, default: 0] += 1
                byRelation[row.link.relation.rawValue, default: 0] += 1
                let evidence = row.link.evidence.flatMap { $0.json } ?? ""
                rows.append([seeded.names[id] ?? "", key.kind.rawValue, row.link.relation.rawValue,
                             texts[key] ?? "", seeded.names[row.earlierMeetingID] ?? "", row.earlierText, evidence].map(cell).joined(separator: "\t"))
                sealed.append([seeded.names[id] ?? "", key.kind.rawValue, texts[key] ?? "", row.earlierText, row.link.method.rawValue,
                               String(format: "%.3f", row.link.score ?? 0)].map(cell).joined(separator: "\t"))
            }
        }
        try (rows.joined(separator: "\n") + "\n").write(to: o.out.appendingPathComponent("links/\(cluster.id).\(label).tsv"), atomically: true, encoding: .utf8)
        let sealedDirectory = o.out.appendingPathComponent("links/sealed")
        try FileManager.default.createDirectory(at: sealedDirectory, withIntermediateDirectories: true)
        try (sealed.joined(separator: "\n") + "\n").write(to: sealedDirectory.appendingPathComponent("\(cluster.id).\(label).tsv"), atomically: true, encoding: .utf8)
        detail["shown"] = "\(shown)"
        for (method, n) in byMethod { detail["method_\(method)"] = "\(n)" }
        for (relation, n) in byRelation { detail["relation_\(relation)"] = "\(n)" }
        return (Array(providers.chatModel.records.dropFirst(before)), detail)
    }

    static func itemTexts(_ store: MeetingStore, meeting: Int64) async throws -> [LinkRowKey: String] {
        var out: [LinkRowKey: String] = [:]
        for t in try await store.tasks(meeting) { out[LinkRowKey(kind: .task, itemID: t.id)] = t.text }
        for d in try await store.decisions(meeting) { out[LinkRowKey(kind: .decision, itemID: d.id)] = d.text }
        return out
    }
}
