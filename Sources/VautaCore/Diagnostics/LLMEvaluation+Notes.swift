// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// `llm-eval --tasks live-notes|notepad|ask-cross`: EVALUATION ONLY. The three features the minutes and live-answer tasks do not reach:
/// the live notes taken while a meeting records, the expansion of the user's shorthand notes (live pass while recording, then the
/// manual pass after the meeting, "Expand Again"), and Ask over the stored meetings of a series. Public transcripts and the notes of the
/// evaluation sets only, a throwaway encrypted store per provider and meeting, no model server. The meeting replays as a recording
/// (the app's live rules; the integrated model reads it as the segments arrive, as it does in the app); the two providers are
/// interleaved at every step (which one goes first alternates).
extension LLMEvaluation {
    struct ShorthandNote: Decodable {
        let id: String
        let after_seg: Int64
        let t_sec: Double
        let text: String
    }

    struct ShorthandRecord: Decodable {
        let meeting: String
        let notes: [ShorthandNote]
    }

    struct CrossQuestion: Decodable {
        let qid: String
        let series: String?
        let meetings: [String]
        let question: String
        let question_language: String?
        let category: String?
        let answerable: Bool?
    }

    /// One provider's store and service for one replayed meeting.
    final class ReplayRig {
        let kind: String
        let model: EvaluationModel
        let providers: EvaluationProviders
        let store: MeetingStore
        let service: LLMService
        let directory: URL
        var meeting: Int64 = 0
        var passageOf: [Int64: Int64] = [:]
        var charsSinceRead = 0
        /// Shorthand notes: the evaluation's key to the stored row, and the attempts the live pass has used.
        var noteRows: [(key: String, id: Int64, t: Double, text: String)] = []
        var attempts: [Int64: Int] = [:]
        var done: Set<Int64> = []

        init(kind: String, options o: Options, languageStore: LanguageModelStore, engine: LanguageModelEngine) async throws {
            self.kind = kind
            model = LLMEvaluation.model(kind, store: languageStore, greedy: o.greedy, engine: engine)
            providers = EvaluationProviders(model, searchModel: o.searchModel)
            if let why = providers.unavailable { throw MinutesEvaluation.Failure.modelUnavailable(why) }
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-notes-eval-\(UUID().uuidString)", isDirectory: true)
            store = try MeetingStore(directory: directory, keyStore: MemoryKeyStore())
            service = LLMService(store: store, providers: providers, searchDefaults: EvaluationDefaults.suite)   // never .standard
            await service.forgetSearchModelCoverage()
            await LLMEvaluation.configureAsk(service, o)
            await service.setLiveHarness(o.live ?? .shipped(integrated: kind == "integrated"))
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        func start(locale: Locale, at date: Date, recording: Bool) async throws {
            meeting = try await store.startMeeting(at: date, locale: locale, outputLocale: locale)
            if recording { await service.setRecording(true, meetingID: meeting) }
        }

        /// Stores one passage as a final segment; the integrated model reads the meeting every ~600 characters while it records.
        func append(_ p: MinutesEvaluation.Passage, start: Double, warm: Bool) async throws {
            let line = p.speaker.map { "\($0): \(p.text)" } ?? p.text
            let id = try await store.append(Segment(channel: .others, start: start, end: start + 8, text: line, isFinal: true), to: meeting)
            passageOf[id] = p.id
            guard warm, kind == "integrated" else { return }
            await service.segmentSaved(meetingID: meeting, segmentID: id, speaker: nil, characters: line.count)
            charsSinceRead += line.count
            if charsSinceRead >= 600 {
                charsSinceRead = 0
                await service.readMeetingNow(meeting)
            }
        }
    }

    static func loadTranscript(_ file: URL) -> (name: String, transcript: MinutesEvaluation.Transcript, locale: Locale)? {
        guard let data = FileManager.default.contents(atPath: file.path),
              let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data), !transcript.passages.isEmpty else { return nil }
        let name = file.deletingPathExtension().lastPathComponent
        return (name, transcript, Locale(identifier: transcript.language == "es" ? "es-ES" : "en-US"))
    }

    static func jsonLine(_ object: [String: Any], to url: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) { appendLine(d, to: url) }
    }

    // MARK: Live notes

    /// The app's cadence (`LiveNotesSchedule`, as `RecorderModel.considerLiveNotes` runs it): every 2100 characters, or when 180 s
    /// have passed and something is new (the first call as soon as there is a line), measured on the transcript's own clock.
    static func runLiveNotes(_ o: Options, store: LanguageModelStore, engine: LanguageModelEngine, write: (Trace) -> Void) async throws {
        var files = setFiles(o)
        if let m = o.maxItems { files = Array(files.prefix(m)) }
        let out = o.out.appendingPathComponent("livenotes")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var pair = 0
        for file in files {
            guard let (name, transcript, locale) = loadTranscript(file) else { continue }
            var rigs: [ReplayRig] = []
            for kind in o.providers { rigs.append(try await ReplayRig(kind: kind, options: o, languageStore: store, engine: engine)) }
            defer { rigs.forEach { $0.cleanup() } }
            for rig in rigs { try await rig.start(locale: locale, at: Date(timeIntervalSince1970: 1_104_537_600), recording: true) }
            var clock = 0.0, chars = 0, tick = 0
            var lastTick: Double?
            for p in transcript.passages {
                let start = p.start ?? clock
                clock = start + 10
                for rig in rigs { try await rig.append(p, start: start, warm: true) }
                chars += p.text.count
                guard LiveNotesSchedule.starts(newCharacters: chars, sinceLast: lastTick.map { .seconds(start - $0) }, busy: false) else { continue }
                chars = 0
                lastTick = start
                let (waited, _) = await waitForQuiet(o)
                let sequence = order(pair, o.providers)
                for kind in sequence {
                    guard let rig = rigs.first(where: { $0.kind == kind }) else { continue }
                    let before = rig.providers.chatModel.records.count
                    var record: [String: Any] = [:]
                    let trace = await measure(task: "live-notes", provider: kind, item: "\(name).t\(tick)", pair: pair, order: sequence[0] == o.providers[0] ? "AB" : "BA",
                                              model: rig.model, waited: waited, options: o) {
                        let batch = try await rig.service.liveNotes(meetingID: rig.meeting, at: start)
                        func cite(_ s: Int64?) -> Any { s.flatMap { rig.passageOf[$0] } ?? NSNull() }
                        record["points"] = (batch?.points ?? []).map { ["text": $0.text as Any, "seg": cite($0.segment)] }
                        record["decisions"] = (batch?.decisions ?? []).map { ["text": $0.text as Any, "seg": cite($0.segment)] }
                        record["tasks"] = (batch?.tasks ?? []).map { ["text": $0.text as Any, "owner": ($0.owner as Any?) ?? NSNull(), "seg": cite($0.segment)] }
                        let all = (batch?.points.count ?? 0) + (batch?.decisions.count ?? 0) + (batch?.tasks.count ?? 0)
                        return (Array(rig.providers.chatModel.records.dropFirst(before)),
                                ["live": (o.live ?? .shipped(integrated: kind == "integrated")).names, "tick": "\(tick)", "t": String(format: "%.0f", start), "returned": "\(batch != nil)", "items": "\(all)",
                                 "points": "\(batch?.points.count ?? 0)", "decisions": "\(batch?.decisions.count ?? 0)", "tasks": "\(batch?.tasks.count ?? 0)"])
                    }
                    write(trace)
                    record["meeting"] = name; record["tick"] = tick; record["t"] = start; record["provider"] = kind; record["error"] = trace.error ?? NSNull()
                    jsonLine(record, to: out.appendingPathComponent("livenotes.\(kind).jsonl"))
                }
                pair += 1
                tick += 1
            }
        }
    }

    // MARK: Notepad enrichment

    static func runNotepad(_ o: Options, store: LanguageModelStore, engine: LanguageModelEngine, write: (Trace) -> Void) async throws {
        guard let url = o.notepad, let text = try? String(contentsOf: url, encoding: .utf8) else { throw MinutesEvaluation.Failure.noAnswer }
        let records = Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { try? JSONDecoder().decode(ShorthandRecord.self, from: Data($0.utf8)) }.map { ($0.meeting, $0) })
        var files = setFiles(o).filter { records[$0.deletingPathExtension().lastPathComponent] != nil }
        if let m = o.maxItems { files = Array(files.prefix(m)) }
        let out = o.out.appendingPathComponent("notepad")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var pair = 0
        for file in files {
            guard let (name, transcript, locale) = loadTranscript(file), let record = records[name] else { continue }
            var rigs: [ReplayRig] = []
            for kind in o.providers { rigs.append(try await ReplayRig(kind: kind, options: o, languageStore: store, engine: engine)) }
            defer { rigs.forEach { $0.cleanup() } }
            let date = Date(timeIntervalSince1970: 1_104_537_600)
            for rig in rigs { try await rig.start(locale: locale, at: date, recording: true) }
            var heard: [(start: Double, characters: Int)] = []
            var clock = 0.0
            func save(_ rig: ReplayRig, _ row: (key: String, id: Int64, t: Double, text: String), pass: String) async {
                let stored = try? await rig.store.expansion(of: row.id)
                var sentences: [[String: Any]] = []
                for s in stored?.sentences ?? [] {
                    sentences.append(["text": s.text, "cites": s.cites.map { rig.passageOf[$0.seg] ?? -1 }, "quote": s.quote, "unconfirmed": s.unconfirmed, "differs": s.differs])
                }
                jsonLine(["meeting": name, "note": row.key, "note_text": row.text, "t": row.t, "pass": pass, "provider": rig.kind,
                          "state": stored?.state.rawValue ?? "none", "sentences": sentences], to: out.appendingPathComponent("notepad.\(rig.kind).jsonl"))
            }
            for p in transcript.passages {
                let start = p.start ?? clock
                clock = start + 10
                for rig in rigs {
                    try await rig.append(p, start: start, warm: true)
                    for n in record.notes where n.after_seg == p.id {
                        let id = try await rig.store.addNote(rig.meeting, at: n.t_sec, text: n.text)
                        rig.noteRows.append((n.id, id, n.t_sec, n.text))
                    }
                }
                heard.append((start, p.text.count))
                // The live pass: a note is expanded once its context is there and it has settled (`NoteExpansionPolicy`).
                let sequence = order(pair, o.providers)
                for kind in sequence {
                    guard let rig = rigs.first(where: { $0.kind == kind }) else { continue }
                    while true {
                        let pending = rig.noteRows.filter { rig.attempts[$0.id] ?? 0 < NoteExpansionPolicy.maxLiveAttempts }
                            .map { NoteExpansionPolicy.Pending(noteID: $0.id, t: $0.t, attempts: rig.attempts[$0.id] ?? 0) }
                            .filter { pending in !rig.done.contains(pending.noteID) }
                        guard let next = NoteExpansionPolicy.next(pending: pending, transcript: heard, now: start, inFlight: false),
                              let row = rig.noteRows.first(where: { $0.id == next.noteID }) else { break }
                        let (waited, _) = await waitForQuiet(o)
                        let before = rig.providers.chatModel.records.count
                        let repliesBefore = rig.providers.chatModel.replies.count
                        let trace = await measure(task: "notepad-live", provider: kind, item: "\(name).\(row.key)", pair: pair, order: sequence[0] == o.providers[0] ? "AB" : "BA",
                                                  model: rig.model, waited: waited, options: o) {
                            let state = try await rig.service.expandNoteLive(meetingID: rig.meeting, noteID: row.id)
                            return (Array(rig.providers.chatModel.records.dropFirst(before)), ["state": state.rawValue, "pass": "live"])
                        }
                        write(trace)
                        saveReplies(rig, row.key, pass: "live", since: repliesBefore, error: trace.error, to: out)
                        if trace.error != nil { rig.attempts[row.id, default: 0] += 1 } else { rig.done.insert(row.id); await save(rig, row, pass: "live") }
                    }
                }
                pair += 1
            }
            // The notes that never became ready while recording (or kept failing): recorded as such, then expanded after the meeting.
            for rig in rigs {
                for row in rig.noteRows where !rig.done.contains(row.id) {
                    jsonLine(["meeting": name, "note": row.key, "note_text": row.text, "t": row.t, "pass": "live", "provider": rig.kind, "state": "not_run",
                              "sentences": [] as [Any]], to: out.appendingPathComponent("notepad.\(rig.kind).jsonl"))
                }
            }
            // After the meeting: "Expand Again" (the manual pass, the main model, the minutes around the note).
            for rig in rigs {
                await rig.service.setRecording(false, meetingID: rig.meeting)
                try await rig.store.endMeeting(rig.meeting, at: date + clock + 5)
            }
            for key in record.notes.map(\.id) {
                let (waited, _) = await waitForQuiet(o)
                let sequence = order(pair, o.providers)
                for kind in sequence {
                    guard let rig = rigs.first(where: { $0.kind == kind }), let row = rig.noteRows.first(where: { $0.key == key }) else { continue }
                    let before = rig.providers.chatModel.records.count
                    let repliesBefore = rig.providers.chatModel.replies.count
                    let trace = await measure(task: "notepad-manual", provider: kind, item: "\(name).\(key)", pair: pair, order: sequence[0] == o.providers[0] ? "AB" : "BA",
                                              model: rig.model, waited: waited, options: o) {
                        let state = try await rig.service.expandNote(noteID: row.id)
                        return (Array(rig.providers.chatModel.records.dropFirst(before)), ["state": state.rawValue, "pass": "manual"])
                    }
                    write(trace)
                    saveReplies(rig, row.key, pass: "manual", since: repliesBefore, error: trace.error, to: out)
                    await save(rig, row, pass: trace.error == nil ? "manual" : "manual_failed")
                }
                pair += 1
            }
        }
    }

    /// The raw replies a notepad request got (answered calls only), next to the stored sentences, so a cut or an invalid reply can be read.
    static func saveReplies(_ rig: ReplayRig, _ key: String, pass: String, since: Int, error: String?, to out: URL) {
        let replies = Array(rig.providers.chatModel.replies.dropFirst(since))
        guard !replies.isEmpty || error != nil else { return }
        jsonLine(["note": key, "pass": pass, "provider": rig.kind, "error": error ?? NSNull(), "replies": replies], to: out.appendingPathComponent("replies.\(rig.kind).jsonl"))
    }

    // MARK: Ask over the stored meetings of a series

    static func runAskCross(_ o: Options, store: LanguageModelStore, engine: LanguageModelEngine, write: (Trace) -> Void) async throws {
        guard let url = o.crossQuestions, let text = try? String(contentsOf: url, encoding: .utf8) else { throw MinutesEvaluation.Failure.noAnswer }
        var questions = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(CrossQuestion.self, from: Data($0.utf8)) }
        if let only = o.only { questions = questions.filter { $0.qid.contains(only) } }
        if let m = o.maxItems { questions = Array(questions.prefix(m)) }
        let out = o.out.appendingPathComponent("answers")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var pair = 0
        let groups = Dictionary(grouping: questions, by: { $0.meetings.joined(separator: "+") })
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            var rigs: [ReplayRig] = []
            for kind in o.providers { rigs.append(try await ReplayRig(kind: kind, options: o, languageStore: store, engine: engine)) }
            defer { rigs.forEach { $0.cleanup() } }
            var owner: [Int64: String] = [:]   // stored segment id -> "meeting:passage" (the ids are the same in every rig: same inserts)
            var loaded = true
            for (index, meetingName) in first.meetings.enumerated() {
                guard let (_, transcript, locale) = loadTranscript(o.sets.appendingPathComponent(meetingName + ".json")) else { loaded = false; break }
                let date = Date(timeIntervalSince1970: 1_104_537_600 + Double(index) * 7 * 86_400)
                var clock = 0.0
                for rig in rigs {
                    try await rig.start(locale: locale, at: date, recording: false)
                    clock = 0
                    for p in transcript.passages {
                        let start = p.start ?? clock
                        clock = start + 10
                        try await rig.append(p, start: start, warm: false)
                    }
                    try await rig.store.endMeeting(rig.meeting, at: date + clock + 5)
                    for (id, passage) in rig.passageOf where owner[id] == nil { owner[id] = "\(meetingName):\(passage)" }
                    rig.passageOf = [:]
                }
            }
            guard loaded else { continue }
            for q in group {
                let (waited, _) = await waitForQuiet(o)
                let sequence = order(pair, o.providers)
                for kind in sequence {
                    guard let rig = rigs.first(where: { $0.kind == kind }) else { continue }
                    var answerText = "", cited: [String] = [], sent: [String] = []
                    let before = rig.providers.chatModel.records.count
                    let trace = await measure(task: "ask-cross", provider: kind, item: q.qid, pair: pair, order: sequence[0] == o.providers[0] ? "AB" : "BA",
                                              model: rig.model, waited: waited, options: o) {
                        let r = try await rig.service.ask(q.question, meetingID: nil)
                        answerText = r.answer.answer
                        cited = Array(Set(r.answer.claims.flatMap(\.citations).compactMap { owner[$0] })).sorted()
                        sent = Array(Set(r.sent.keys.compactMap { owner[$0] })).sorted()
                        return (Array(rig.providers.chatModel.records.dropFirst(before)),
                                ["claims": "\(r.answer.claims.count)", "verifiedClaims": "\(r.answer.claims.filter(\.verified).count)", "cited": cited.joined(separator: ","),
                                 "found": "\(r.answer.found)", "refused": "\(!r.answer.found && !r.answer.withheldAnAnswer)",
                                 "refusedWithAnswer": "\(!r.answer.found && r.answer.withheldAnAnswer)", "cutShort": "\(r.answer.cutShort)",
                                 "unverified": "\(r.answer.isUnverified)", "answerable": "\(q.answerable ?? true)", "category": q.category ?? "",
                                 "language": q.question_language ?? "", "meetings": q.meetings.joined(separator: ","),
                                 "ask": o.ask.names, "sent": sent.joined(separator: ",")])
                    }
                    write(trace)
                    jsonLine(["case": q.qid, "answer": answerText, "citations": cited, "sent": sent, "reply": rig.providers.chatModel.last ?? "", "error": trace.error ?? NSNull()],
                             to: out.appendingPathComponent("cross.\(kind).jsonl"))
                }
                pair += 1
            }
        }
    }
}
