// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
internal import VautaMLX

/// A replay scenario failed: the run is recorded as an error in the trace, with the counts.
struct ReplayFailure: Error, CustomStringConvertible {
    let failures: Int
    let detail: [String: String]
    var description: String { "replay: \(failures) failed check(s) \(detail.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))" }
}

extension ActionsEvaluation {
    /// One (meeting, backend, arm) run: the throwaway store is seeded, the arm runs, its output is written under a blind label.
    static func run(_ o: LLMEvaluation.Options, store languageStore: LanguageModelStore, engine: LanguageModelEngine, write: (LLMEvaluation.Trace) -> Void) async throws {
        let options = o.actions
        let (fixtures, manifest) = try loadFixtures(options)
        let out = o.out
        for folder in ["emails", "followups", "sealed"] { try FileManager.default.createDirectory(at: out.appendingPathComponent(folder), withIntermediateDirectories: true) }
        if !manifest.isEmpty { try manifest.write(to: out.appendingPathComponent("fixtures.sha256"), atomically: true, encoding: .utf8) }
        let minutes = ["apple": BriefEvaluation.loadMinutes(options.minutes["apple"]), "integrated": BriefEvaluation.loadMinutes(options.minutes["integrated"])]
        var files = LLMEvaluation.setFiles(o)
        if let m = o.maxItems { files = Array(files.prefix(m)) }
        var labels = Labels()
        var pair = 0
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path),
                  let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data), !transcript.passages.isEmpty else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let (waited, _) = await LLMEvaluation.waitForQuiet(o)
            // The arms of this meeting: backend-independent ones once, the others for each backend that has stored minutes.
            var arms: [(kind: Kind, provider: String)] = []
            for kind in options.kinds {
                if kind.usesMinutes || kind.usesModel {
                    for provider in o.providers where !kind.usesMinutes || !(minutes[provider]?[name] == nil) { arms.append((kind, provider)) }
                } else {
                    arms.append((kind, "none"))
                }
            }
            let sequence = LLMEvaluation.order(pair, arms.map { "\($0.kind.rawValue)/\($0.provider)" })
            for entry in sequence {
                guard let arm = arms.first(where: { "\($0.kind.rawValue)/\($0.provider)" == entry }) else { continue }
                let provider = arm.provider == "none" ? "apple" : arm.provider
                let model = LLMEvaluation.model(provider, store: languageStore, greedy: o.greedy, engine: engine)
                let label = labels.label(meeting: name, kind: arm.kind, provider: arm.provider)
                let trace = await LLMEvaluation.measure(task: "actions", provider: arm.provider, item: "\(name).\(label)", pair: pair,
                                                        order: sequence.first == entry ? "first" : "later", model: model, waited: waited, options: o) {
                    try await runArm(arm.kind, provider: arm.provider, name: name, label: label, transcript: transcript, fixture: fixtures[name],
                                     minutes: arm.provider == "none" ? nil : minutes[arm.provider]?[name], model: model, options: o)
                }
                write(trace)
            }
            pair += 1
        }
        // The key is sealed: written once, hashed, and not read until the judge's grades are.
        let key = try JSONSerialization.data(withJSONObject: labels.key, options: [.sortedKeys, .prettyPrinted])
        try key.write(to: out.appendingPathComponent("sealed/key.json"))
        try (SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() + "  key.json\n").write(to: out.appendingPathComponent("sealed/key.sha256"), atomically: true, encoding: .utf8)
    }

    static func runArm(_ kind: Kind, provider: String, name: String, label: String, transcript: MinutesEvaluation.Transcript, fixture: Fixture?,
                       minutes: BriefEvaluation.StoredMinutes?, model: EvaluationModel, options o: LLMEvaluation.Options) async throws -> (calls: [EvaluationCall], detail: [String: String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-actions-eval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seeded = try await seed(name: name, transcript: transcript, fixture: fixture, minutes: minutes, directory: directory, nameSpeakers: o.actions.nameSpeakers)
        var detail: [String: String] = ["arm": label, "tasks": "\(seeded.tasks.count)", "unmapped": "\(seeded.unmapped)", "language": seeded.locale.identifier]
        var calls: [EvaluationCall] = []

        switch kind {
        case .et1, .eto:
            let input = try await seeded.store.followUpEmailInput(seeded.meetingID)
            guard let input else { return ([], detail) }
            let options = FollowUpEmailOptions(locale: seeded.locale, mode: kind == .et1 ? .one : .perOwner, includeSummary: false)
            let drafts = FollowUpEmail.drafts(input, options: options)
            var violations = 0
            for (i, draft) in drafts.enumerated() {
                violations += FollowUpEmailTracer.violations(draft, input: input).count
                let text = "Subject: \(draft.subject)\n\n" + draft.plainText
                try text.write(to: o.out.appendingPathComponent("emails/\(name).\(label)\(drafts.count > 1 ? ".\(i + 1)" : "").txt"), atomically: true, encoding: .utf8)
            }
            detail["drafts"] = "\(drafts.count)"
            detail["tracerViolations"] = "\(violations)"
        case .ebl:
            guard let minutes else { return ([], detail) }
            let providers = EvaluationProviders(model)
            let language = OutputLanguage(seeded.locale)
            var lines = ["Meeting: \(name), \(DueDay.containing(seeded.start, in: seeded.zone).string)", "Summary: \(minutes.summary ?? "")"]
            lines += (minutes.decisions ?? []).map { "Decision: \($0.text)" } + (minutes.tasks ?? []).map { "Task: \($0.text)\($0.owner.map { " (owner \($0))" } ?? "")\($0.due.map { " (due \($0))" } ?? "")" }
            lines += (minutes.open_questions ?? []).map { "Open question: \($0)" }
            let messages: [ChatMessage] = [
                .system("You write the follow-up email that a person sends after a meeting, from its minutes. List the decisions and the next steps with their owners and due dates. Be short. \(language.instruction)"),
                .user(lines.joined(separator: "\n"))]
            let before = providers.chatModel.records.count
            let text = try await providers.chatModel.chat(messages, ChatOptions(model: .deep, maxTokens: 700, purpose: .other, priority: .brief), onProgress: nil).content
            calls = Array(providers.chatModel.records.dropFirst(before))
            try text.trimmingCharacters(in: .whitespacesAndNewlines).write(to: o.out.appendingPathComponent("emails/\(name).\(label).txt"), atomically: true, encoding: .utf8)
        case .fd, .fdx:
            let candidates = kind == .fd ? try await seeded.store.detectFollowUps(seeded.meetingID) : try await detectEverywhere(seeded)
            try writeFollowUps(candidates.map { ($0.day, $0.minuteOfDay, $0.dayInferred) }, to: o.out.appendingPathComponent("followups/\(name).\(label).json"))
            detail["candidates"] = "\(candidates.count)"
        case .fbl:
            let providers = EvaluationProviders(model)
            let segments = try await seeded.store.segments(of: seeded.meetingID)
            let tail = segments.suffix(max(8, Int((Double(segments.count) * 0.1).rounded(.up))))
            let today = DueDay.containing(seeded.start, in: seeded.zone)
            let messages: [ChatMessage] = [
                .system("You read the end of a meeting transcript. If the people agreed on the day of their next meeting, answer with JSON {\"next_meeting\": {\"date\": \"YYYY-MM-DD\", \"time\": \"HH:MM or null\"}}. If not, answer {\"next_meeting\": null}. Answer with JSON only."),
                .user("The meeting took place on \(today.string) (\(today.formatted(locale: Locale(identifier: "en_US")))).\n\nEnd of the transcript:\n" + tail.map(\.text).joined(separator: "\n"))]
            let before = providers.chatModel.records.count
            let text = try await providers.chatModel.chat(messages, ChatOptions(model: .deep, maxTokens: 120, purpose: .other, priority: .brief), onProgress: nil).content
            calls = Array(providers.chatModel.records.dropFirst(before))
            let parsed = parseNextMeeting(text)
            try writeFollowUps(parsed.map { [($0.day, $0.minute, false)] } ?? [], to: o.out.appendingPathComponent("followups/\(name).\(label).json"))
            detail["candidates"] = "\(parsed == nil ? 0 : 1)"
        case .rp:
            let report = await replay(seeded: seeded, fixture: fixture, directory: directory)
            detail.merge(report.detail) { _, new in new }
            if report.failures > 0 { throw ReplayFailure(failures: report.failures, detail: report.detail) }
            if let d = try? JSONSerialization.data(withJSONObject: report.detail.merging(["meeting": name, "provider": provider]) { _, new in new }, options: [.sortedKeys]) {
                LLMEvaluation.appendLine(d, to: o.out.appendingPathComponent("replay.jsonl"))
            }
        }
        return (calls, detail)
    }

    /// The detector reading every segment, as if all were cited: the ceiling of what the rules can find.
    static func detectEverywhere(_ seeded: Seeded) async throws -> [FollowUpCandidate] {
        let segments = try await seeded.store.segments(of: seeded.meetingID)
        let tasks = try await seeded.store.tasks(seeded.meetingID)
        let input = FollowUpInput(lines: segments.map { .init(id: $0.id, start: $0.start, end: $0.end, text: $0.text) }, citedSegments: Set(segments.map(\.id)),
                                  tasks: tasks.map { .init(segmentID: $0.segmentID, text: $0.text, dueDay: $0.dueDay, unconfirmed: $0.unconfirmed) }, meetingStart: seeded.start, timeZone: seeded.zone,
                                  locale: seeded.locale.identifier, meetingTitle: "", meetingDuration: nil)
        return FollowUpDetector.detect(input)
    }

    static func writeFollowUps(_ rows: [(day: DueDay?, minute: Int?, inferred: Bool)], to url: URL) throws {
        let objects: [[String: Any]] = rows.map { r in
            var o: [String: Any] = ["inferred": r.inferred]
            if let day = r.day { o["day"] = day.string }
            if let minute = r.minute { o["minute"] = minute }
            return o
        }
        try JSONSerialization.data(withJSONObject: ["candidates": objects], options: [.sortedKeys]).write(to: url)
    }

    /// The baseline's answer, read leniently (a JSON object somewhere in the text). The day is checked to be a real date; nothing else is.
    static func parseNextMeeting(_ text: String) -> (day: DueDay, minute: Int?)? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any],
              let next = object["next_meeting"] as? [String: Any], let date = next["date"] as? String, let day = DueDay(date) else { return nil }
        var minute: Int?
        if let time = next["time"] as? String {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) { minute = parts[0] * 60 + parts[1] }
        }
        return (day, minute)
    }
}
