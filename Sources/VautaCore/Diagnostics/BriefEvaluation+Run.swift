// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import VautaMLX

/// The run of `llm-eval --tasks brief`: one throwaway store per series and arm, seeded with the meetings before the briefed one, their
/// stored minutes, the fixture documents and notes; then the brief is built, the agenda written and checked, and everything counted.
extension BriefEvaluation {
    static let referenceDate = Date(timeIntervalSince1970: 1_104_537_600)

    static func localeFor(_ fixture: Fixture) -> Locale { Locale(identifier: fixture.language == "es" ? "es-ES" : "en-US") }

    /// The event of a fixture: the meeting starts a week after the last earlier one.
    static func event(_ f: Fixture, start: Date, briefed: Bool = true) -> BriefEvent {
        let people = f.event.attendees + (briefed ? f.event.newAttendees ?? [] : [])
        let attendees = [BriefAttendee(name: "Me", email: nil, isCurrentUser: true)] + people.map { BriefAttendee(name: $0.name, email: $0.email) }
        return BriefEvent(identifier: "eval-\(f.series)", title: f.event.title, start: start, end: start.addingTimeInterval(3_600), calendarID: "eval", attendees: attendees,
                          isRecurring: !f.earlier.isEmpty, service: f.event.service.flatMap { ConferencingService(rawValue: $0) }, invitationNotes: f.event.invitationNotes)
    }

    /// The earlier meetings and their stored minutes in the store, oldest first. Returns the meeting IDs.
    static func seed(_ f: Fixture, sets: URL, minutes: [String: StoredMinutes], store: MeetingStore, start: Date) async throws -> [Int64] {
        let locale = localeFor(f)
        var ids: [Int64] = []
        for (i, name) in f.earlier.enumerated() {
            guard let data = FileManager.default.contents(atPath: sets.appendingPathComponent(name + ".json").path),
                  let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data) else { throw Failure.missingTranscript(name) }
            let when = start.addingTimeInterval(-Double(f.earlier.count - i) * 7 * 86_400)
            let id = try await store.startMeeting(at: when, locale: locale, outputLocale: locale)
            for l in LLMEvaluation.replayLines(transcript) {
                _ = try await store.append(Segment(channel: .others, start: l.start, end: l.end, text: l.stored, isFinal: true), to: id)
            }
            let calendar = event(f, start: when, briefed: false).calendarMeeting
            _ = try await store.applyCalendar(calendar, to: id)
            try await store.endMeeting(id, at: when.addingTimeInterval(2_700))
            if let m = minutes[name] {
                try await store.saveCard(MeetingCard(summary: m.summary ?? "", topics: [], openQuestions: m.open_questions ?? []), of: id)
                for d in m.decisions ?? [] { _ = try await store.addDecision(id, text: d.text, source: "llm") }
                for t in m.tasks ?? [] {
                    var owner: Int64?
                    if let label = t.owner, let person = f.speakers?[label] { owner = try await store.entities(.person).first { $0.name == person }?.id }
                    _ = try await store.addTask(id, text: t.text, ownerID: owner, due: t.due.flatMap { PromptText.parseDay($0, reference: when) }, source: "llm")
                }
            }
            ids.append(id)
        }
        return ids
    }

    static func writeFolder(_ documents: [Fixture.Document], to url: URL) throws -> Bool {
        guard !documents.isEmpty else { return false }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for d in documents { try d.text.write(to: url.appendingPathComponent(d.name), atomically: true, encoding: .utf8) }
        return true
    }

    static func run(_ o: LLMEvaluation.Options, store languageStore: LanguageModelStore, engine: LanguageModelEngine, write: (LLMEvaluation.Trace) -> Void) async throws {
        let options = o.brief
        let fixtures = try loadFixtures(options)
        let out = o.out.appendingPathComponent("briefs")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let manifest = fixtures.map { "\($0.hash)  \($0.file)" }.joined(separator: "\n") + "\n"
        try manifest.write(to: o.out.appendingPathComponent("fixtures.sha256"), atomically: true, encoding: .utf8)
        let minutes = ["apple": loadMinutes(options.minutes["apple"]), "integrated": loadMinutes(options.minutes["integrated"])]
        let arms = options.arms.filter { ($0.semantic ? o.searchModel != nil : true) && ($0.provider != nil ? o.providers.contains($0.provider!) : true) }
        var pair = 0
        for (fixture, _, _) in fixtures {
            let (waited, _) = await LLMEvaluation.waitForQuiet(o)
            let sequence = LLMEvaluation.order(pair, arms.map(\.name))
            for name in sequence {
                guard let arm = arms.first(where: { $0.name == name }) else { continue }
                let model = arm.provider.map { LLMEvaluation.model($0, store: languageStore, greedy: o.greedy, engine: engine) } ?? .apple
                var rendered = ""
                var record: [String: Any] = [:]
                let trace = await LLMEvaluation.measure(task: "brief", provider: arm.provider ?? "none", item: "\(fixture.series).\(arm.name)", pair: pair,
                                                        order: sequence.first == arms.first?.name ? "AB" : "BA", model: model, waited: waited, options: o) {
                    let run = try await runArm(arm, fixture: fixture, options: o, model: model, minutes: minutes)
                    rendered = run.text
                    record = run.record
                    return (run.calls, run.detail)
                }
                write(trace)
                record["series"] = fixture.series
                record["briefed"] = fixture.briefed
                record["arm"] = arm.name
                record["text"] = rendered
                try? rendered.write(to: out.appendingPathComponent("\(fixture.series).\(arm.name).txt"), atomically: true, encoding: .utf8)
                if let d = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) { LLMEvaluation.appendLine(d, to: out.appendingPathComponent("briefs.jsonl")) }
            }
            pair += 1
        }
    }

    struct ArmRun {
        var text: String
        var record: [String: Any]
        var calls: [EvaluationCall]
        var detail: [String: String]
    }

    static func runArm(_ arm: Arm, fixture f: Fixture, options o: LLMEvaluation.Options, model: EvaluationModel, minutes: [String: [String: StoredMinutes]]) async throws -> ArmRun {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-brief-eval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeetingStore(directory: directory.appendingPathComponent("store"), keyStore: MemoryKeyStore())
        let start = referenceDate
        let used = minutes[arm.provider ?? "integrated"].flatMap { $0.isEmpty ? nil : $0 } ?? minutes["integrated"] ?? minutes["apple"] ?? [:]
        let meetingIDs = try await seed(f, sets: o.sets, minutes: used, store: store, start: start)

        let providers = EvaluationProviders(model, searchModel: arm.semantic ? o.searchModel : nil)
        let service = LLMService(store: store, providers: providers, searchDefaults: EvaluationDefaults.suite)   // never .standard
        await service.forgetSearchModelCoverage()

        // The fixture documents and the exported notes, as two sources of a documents index; the notes folder carries the Notes flag.
        let index = try DocumentIndex(directory: store.storeDirectory, key: await store.documentsKey())
        let indexer = DocumentIndexer(store: store, index: index, access: LLMEvaluation.PlainFolderAccess())
        await indexer.start(background: false)
        let docsFolder = directory.appendingPathComponent("documents"), notesFolder = directory.appendingPathComponent("notes")
        if try writeFolder(f.documents, to: docsFolder) { _ = try await indexer.addSource(docsFolder, isDirectory: true) }
        if try writeFolder(f.notes, to: notesFolder) {
            let source = try await indexer.addSource(notesFolder, isDirectory: true)
            try await store.setDocumentSourceNotesExport(source.id, true)
        }
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, await indexer.snapshot().pendingFiles > 0 { try await Task.sleep(for: .milliseconds(50)) }
        await service.setDocuments(index)
        if arm.semantic {
            for id in meetingIDs { try await service.embed(id) }
            _ = await service.embedDocumentPassages(limit: 100_000, allowNetwork: false)
            await service.refreshSearchCoverage()
        }

        let reminders = f.reminders.map { r in
            BriefReminder(id: r.id, title: r.title, due: r.dueDays.map { start.addingTimeInterval($0 * 86_400) }, listID: r.list, listName: r.list)
        }
        let adapters = service.briefAdapters()
        let composer = BriefComposer(store: store, retriever: adapters.retriever, reminders: FixtureReminders(reminders: reminders))
        let briefed = event(f, start: start)
        let settings = BriefSettings(remindersEnabled: true, reminderListIDs: Set(reminders.map(\.listID)), useInvitationNotes: true)
        let before = providers.chatModel.records.count
        var detail: [String: String] = ["arm": arm.name, "series": f.series, "semantic": "\(arm.semantic)", "baseline": "\(arm.baseline)", "earlier": "\(f.earlier.count)"]
        var record: [String: Any] = ["provider": arm.provider ?? "none", "semantic": arm.semantic]

        if arm.baseline {
            // The competitor-style baseline: the same model recaps the last meeting's minutes, with no retrieval and no verifier.
            guard let lastName = f.earlier.last, let last = used[lastName] else { return ArmRun(text: "", record: record, calls: [], detail: detail) }
            let language = OutputLanguage(localeFor(f))
            var lines = ["Summary: \(last.summary ?? "")"]
            lines += (last.decisions ?? []).map { "Decision: \($0.text)" } + (last.tasks ?? []).map { "Task: \($0.text)" } + (last.open_questions ?? []).map { "Open question: \($0)" }
            let messages: [ChatMessage] = [
                .system("You prepare a person for their next meeting. You are given the minutes of the previous meeting. Write a short brief of what to remember and what to follow up on, in at most 150 words. \(language.instruction)"),
                .user("Meeting: \(f.event.title)\n\nMinutes of the previous meeting:\n" + lines.joined(separator: "\n"))]
            let started = Date()
            let budget = ContextBudget(contextTokens: max(2_048, providers.contextTokens))
            let text = try await providers.chatModel.chat(messages, ChatOptions(model: .deep, maxTokens: budget.briefOutput, purpose: .brief, priority: .brief), onProgress: nil).content
            detail["agendaSeconds"] = String(format: "%.3f", Date().timeIntervalSince(started))
            return ArmRun(text: text.trimmingCharacters(in: .whitespacesAndNewlines), record: record, calls: Array(providers.chatModel.records.dropFirst(before)), detail: detail)
        }

        let t0 = Date()
        let result = await composer.build(briefed, settings: settings, environment: BriefEnvironment(), backend: nil, now: start.addingTimeInterval(-600))
        detail["composeSeconds"] = String(format: "%.3f", Date().timeIntervalSince(t0))
        guard var snapshot = result.snapshot else { return ArmRun(text: "", record: record, calls: [], detail: detail) }
        // The same inputs must give the same brief.
        let again = await composer.build(briefed, settings: settings, environment: BriefEnvironment(), backend: nil, now: start.addingTimeInterval(-600))
        detail["deterministic"] = "\(again.snapshot?.digest == snapshot.digest)"
        detail["mode"] = snapshot.mode.rawValue
        if arm.semantic && snapshot.mode != .semantic { detail["semanticFellBack"] = "true" }

        if let provider = arm.provider {
            let backend: BriefBackend = provider == "integrated" ? .integrated : .apple
            let budget = ContextBudget(contextTokens: max(2_048, providers.contextTokens))
            let box = ReportBox()
            let a0 = Date()
            snapshot.agenda = await BriefAgenda.run(snapshot: snapshot, backend: backend, writer: adapters.writer, language: OutputLanguage(localeFor(f)), budget: budget,
                                                    environment: BriefEnvironment(), integratedLoaded: true, report: { box.set($0) })
            detail["agendaSeconds"] = String(format: "%.3f", Date().timeIntervalSince(a0))
            if let r = box.value {
                detail["agendaProposed"] = "\(r.proposed)"
                detail["agendaAccepted"] = "\(r.accepted)"
                detail["agendaOffered"] = "\(r.offered)"
                detail["agendaPromptTokens"] = "\(r.promptTokens)"
                for (reason, n) in r.rejected { detail["rejected_" + reason.rawValue] = "\(n)" }
            }
            detail["agenda"] = "\(snapshot.agenda)".prefix(40).description
            record["agenda"] = snapshot.agenda.lines.map { ["kind": $0.kind.rawValue, "text": $0.text, "cites": $0.cites] as [String: Any] }
        }

        let checks = await check(snapshot, fixture: f, store: store, reminderIDs: Set(reminders.map(\.id)), minutes: f.earlier.compactMap { used[$0] })
        detail["items"] = "\(checks.items)"
        detail["linksInvalid"] = "\(checks.linksInvalid)"
        detail["wrongAttribution"] = "\(checks.wrongAttribution)"
        detail["distractorsShown"] = "\(checks.distractorsShown)"
        detail["inventedHistory"] = "\(checks.inventedHistory)"
        detail["relatedSkipped"] = "\(snapshot.relatedSkipped)"
        for section in snapshot.sections { detail["n_" + section.kind.rawValue] = "\(section.items.count)/\(section.total)" }
        detail["digest"] = snapshot.digest
        record["digest"] = snapshot.digest
        record["mode"] = snapshot.mode.rawValue
        record["sections"] = snapshot.sections.map { s in
            ["kind": s.kind.rawValue, "total": s.total, "items": s.items.map { i in
                ["id": i.id, "kind": i.kind.rawValue, "text": i.text, "meeting": i.meetingID.map { "\($0)" } ?? "", "cosine": i.cosine.map { String(format: "%.3f", $0) } ?? ""] as [String: Any]
            }] as [String: Any]
        }
        return ArmRun(text: render(snapshot), record: record, calls: Array(providers.chatModel.records.dropFirst(before)), detail: detail)
    }

    final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var report: BriefAgenda.Report?
        func set(_ r: BriefAgenda.Report) { lock.withLock { report = r } }
        var value: BriefAgenda.Report? { lock.withLock { report } }
    }
}
