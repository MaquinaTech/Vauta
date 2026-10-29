// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension LLMEvaluation {
    /// `--tasks minutes-replay --replay-from <folder of <meeting>.<provider>.json> --extraction old|new`: the stored replies of an earlier
    /// minutes run, through the app's own validation, item filter and owner rules, with no model. Writes the same files as a minutes run.
    static func runMinutesReplay(_ o: Options, write: (Trace) -> Void) async throws {
        guard let from = o.replayFrom else { throw MinutesEvaluation.Failure.noAnswer }
        var files = setFiles(o)
        if let m = o.maxItems { files = Array(files.prefix(m)) }
        let minutesDir = o.out.appendingPathComponent("minutes")
        try FileManager.default.createDirectory(at: minutesDir, withIntermediateDirectories: true)
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path),
                  let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data), !transcript.passages.isEmpty else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let language = Locale(identifier: transcript.language == "es" || name.hasPrefix("es_") ? "es-ES" : "en-US")
            for kind in o.providers {
                guard let stored = FileManager.default.contents(atPath: from.appendingPathComponent("\(name).\(kind).json").path),
                      let replies = ReplayedReplies(resultFile: stored) else { continue }
                let model = EvaluationModel.replay(kind: kind, replies: replies, liveFinal: o.replayLive)
                let choices = o.minutesChoices(provider: kind)
                let result = try await MinutesEvaluation.run(transcript, language: language, model: model, arms: o.arms, warm: false, extraction: choices.extraction, summary: choices.summary, harness: choices.harness, questions: choices.questions)
                try writeMinutes(result, name: name, kind: kind, to: minutesDir)
                print("replay \(name) \(kind) kept \(result.items.count) extraction \(choices.extraction.names)")
            }
        }
    }

    /// The per-meeting result file and the line of `minutes.<provider>.jsonl` (the shape of tools/llm-eval make_blind_packets.py, plus the
    /// flags the app stores: `unconfirmed`, `owner_uncertain`, `owner_kind`, the cited segments), so the actions evaluation seeds what the app shows.
    static func writeMinutes(_ result: MinutesEvaluation.Result, name: String, kind: String, to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(result).write(to: dir.appendingPathComponent("\(name).\(kind).json"))
        let line: [String: Any] = [
            "case": name, "summary": result.summary, "open_questions": result.openQuestions,
            "decisions": result.items.filter { $0.kind == "decision" }.map { ["text": $0.text, "quote": "", "unconfirmed": $0.unconfirmed, "reason": $0.reason ?? "", "citations": $0.citations] as [String: Any] },
            "tasks": result.items.filter { $0.kind == "task" }.map { item -> [String: Any] in
                ["text": item.text, "owner": item.owner ?? "", "due": item.due ?? "", "unconfirmed": item.unconfirmed, "owner_uncertain": item.ownerUncertain,
                 "owner_kind": item.ownerKind ?? "none", "reason": item.reason ?? "", "citations": item.citations]
            }]
        if let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) { appendLine(d, to: dir.appendingPathComponent("minutes.\(kind).jsonl")) }
    }
}
