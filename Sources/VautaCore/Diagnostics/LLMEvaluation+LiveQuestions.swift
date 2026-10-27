// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import VautaMLX

/// `llm-eval --tasks live-questions`: replays public transcripts through the live-answer pipeline (detection, evidence, model check and
/// answer) with the app's own code, on a simulated clock, and writes one JSON line per candidate sentence. No app UI, no audio, no model
/// server. The earlier meetings of a series (ES2004b before ES2004c) are inserted as past meetings of the replayed one.
extension LLMEvaluation {
    struct SentenceRow: Encodable {
        let meeting: String
        let line: Int64
        let channel: String
        let t: Double
        let end: Double
        let index: Int
        let text: String
        let score: Double
        let cues: [String]
        let mark: Bool
        let hasQuestionMark: Bool
        let context: [String]
    }

    /// The time to the first token of the closing probe (`--closing-probe`).
    final class ClosingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double?
        func set(_ value: Double?) { lock.withLock { seconds = value } }
        var value: Double? { lock.withLock { seconds } }
    }

    /// "ES2004c" → ("ES2004", "c"); "cdm191218_b" → ("cdm191218", "b"). nil when the name has no series part.
    static func series(of name: String) -> (key: String, part: String)? {
        if let underscore = name.lastIndex(of: "_") {
            let part = String(name[name.index(after: underscore)...])
            return part.count <= 3 && !part.isEmpty ? (String(name[..<underscore]), part) : nil
        }
        guard let last = name.last, last.isLetter, last.isLowercase, name.count > 2, name[name.index(before: name.endIndex)...].first?.isLetter == true,
              let beforeLast = name.dropLast().last, beforeLast.isNumber else { return nil }
        return (String(name.dropLast()), String(last))
    }

    static func replayLines(_ transcript: MinutesEvaluation.Transcript) -> [QuestionReplay.Line] {
        var out: [QuestionReplay.Line] = []
        var clock = 0.0
        let passages = transcript.passages
        for (i, p) in passages.enumerated() {
            let start = p.start ?? clock
            let words = max(1, p.text.split(whereSeparator: { $0.isWhitespace }).count)
            var end = start + max(1.0, min(30, Double(words) * 0.4))
            if i + 1 < passages.count, let next = passages[i + 1].start { end = max(start + 0.5, min(end, next - 0.05)) }
            clock = end
            out.append(QuestionReplay.Line(id: p.id, start: start, end: end, channel: .others, text: p.text,
                                           stored: p.speaker.map { "\($0): \(p.text)" } ?? p.text))
        }
        return out
    }

    static func runLiveQuestions(_ o: Options, store: LanguageModelStore, engine: LanguageModelEngine, write: (Trace) -> Void) async throws {
        var files = setFiles(o)
        if let m = o.maxItems { files = Array(files.prefix(m)) }
        let dir = o.out.appendingPathComponent("questions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let sentences = o.questionSentences {
            try writeSentences(files, to: sentences)
            return
        }
        let allFiles = ((try? FileManager.default.contentsOfDirectory(at: o.sets, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
        var pair = 0
        let kinds = o.questionDetectOnly ? ["apple"] : o.providers
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path),
                  let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data), !transcript.passages.isEmpty else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let locale = Locale(identifier: transcript.language == "es" || name.hasPrefix("cdm") || name.hasPrefix("es_") ? "es-ES" : "en-US")
            let lines = replayLines(transcript)
            // The earlier meetings of the series, oldest first.
            var earlier: [(String, MinutesEvaluation.Transcript)] = []
            if o.questionSources.contains(.pastMeetings), let me = series(of: name) {
                for other in allFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let n = other.deletingPathExtension().lastPathComponent
                    guard let s = series(of: n), s.key == me.key, s.part < me.part, let d = FileManager.default.contents(atPath: other.path),
                          let t = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: d) else { continue }
                    earlier.append((n, t))
                }
            }
            let (waited, _) = await waitForQuiet(o)
            let sequence = order(pair, kinds)
            for kind in sequence {
                let model = Self.model(kind, store: store, greedy: o.greedy, engine: engine)
                let providers = EvaluationProviders(model, searchModel: o.searchModel)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-question-eval-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let meetingStore = try MeetingStore(directory: directory, keyStore: MemoryKeyStore())
                let date = Date(timeIntervalSince1970: 1_104_537_600)
                var pastIDs: [Int64] = []
                for (i, past) in earlier.enumerated() {
                    let when = date.addingTimeInterval(-Double(earlier.count - i) * 7 * 86_400)
                    let id = try await meetingStore.startMeeting(at: when, locale: locale, outputLocale: locale)
                    for l in replayLines(past.1) { _ = try await meetingStore.append(Segment(channel: .others, start: l.start, end: l.end, text: l.stored, isFinal: true), to: id) }
                    try await meetingStore.endMeeting(id, at: when.addingTimeInterval(2_700))
                    pastIDs.append(id)
                }
                let meeting = try await meetingStore.startMeeting(at: date, locale: locale, outputLocale: locale)
                let service = LLMService(store: meetingStore, providers: providers, searchDefaults: EvaluationDefaults.suite)   // never .standard
                // The evaluation measures Apple's model too, which the app does not offer for live answers (decision D16).
                service.disableLiveAnswerGate()
                // One set must not read the "coverage reached" marker another left in the shared suite: the mode would depend on the order.
                await service.forgetSearchModelCoverage()
                // With the search model the earlier meetings of the series are embedded, as the app does after they ended. The meeting being
                // replayed is not (the app embeds a meeting once it has ended), so its questions are still ranked by keywords.
                if o.searchModel != nil { for id in pastIDs { try await service.embed(id) } }
                await service.setRecording(true, meetingID: meeting)
                var documentsIndexer: DocumentIndexer?
                var documentCount = 0
                if let root = o.questionDocuments, !o.questionDetectOnly {
                    let folder = root.appendingPathComponent(name, isDirectory: true)
                    if FileManager.default.fileExists(atPath: folder.path) {
                        let index = try DocumentIndex(directory: await meetingStore.storeDirectory, key: await meetingStore.documentsKey())
                        let indexer = DocumentIndexer(store: meetingStore, index: index, access: PlainFolderAccess())
                        await indexer.start(background: false)
                        _ = try await indexer.addSource(folder, isDirectory: true)
                        let deadline = Date().addingTimeInterval(120)
                        while Date() < deadline, await indexer.snapshot().pendingFiles > 0 { try await Task.sleep(for: .milliseconds(50)) }
                        await service.setDocuments(index)
                        documentCount = await indexer.snapshot().sources.first?.counts.indexed ?? 0
                        documentsIndexer = indexer
                    }
                }
                _ = documentsIndexer
                var options = QuestionReplay.Options()
                options.settings.sensitivity = o.questionSensitivity
                options.settings.sources = o.questionSources
                options.settings.hideWhenAnsweredAloud = !o.questionKeepAnsweredAloud
                options.skipCheck = o.questionSkipCheck
                options.detectOnly = o.questionDetectOnly
                options.detection = !o.questionNoDetection
                if o.questionRealtime {
                    let wall0 = Date()
                    options.pace = { simulated in
                        let wait = simulated - Date().timeIntervalSince(wall0)
                        if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
                    }
                }
                let closing = ClosingProbe()
                if o.questionClosingProbe && !o.questionDetectOnly {
                    options.closingProbe = {
                        let first = providers.chatModel.records.count
                        _ = try? await service.ask("What did the group decide?", meetingID: meeting)
                        closing.set(providers.chatModel.records.dropFirst(first).last?.timeToFirstTokenSeconds)
                    }
                }
                options.meetingLocale = locale.identifier
                if kind == "integrated" && !o.questionDetectOnly {
                    options.warmRead = { await service.readMeetingNow(meeting) }
                }
                var rows: [QuestionReplay.Record] = []
                let before = providers.chatModel.records.count
                let trace = await measure(task: "live-questions", provider: o.questionDetectOnly ? "none" : kind, item: name, pair: pair,
                                          order: sequence[0] == kinds[0] ? "AB" : "BA", model: model, waited: waited, options: o) {
                    rows = try await QuestionReplay.run(lines: lines, meetingID: meeting, options: options, backend: service,
                                                        appendLine: { l in try await meetingStore.append(Segment(channel: l.channel, start: l.start, end: l.end, text: l.stored, isFinal: true), to: meeting) })
                    var detail = ["sensitivity": o.questionSensitivity.rawValue, "skipCheck": "\(o.questionSkipCheck)", "detectOnly": "\(o.questionDetectOnly)",
                                  "hideAnsweredAloud": "\(!o.questionKeepAnsweredAloud)", "pastMeetings": "\(earlier.count)", "documents": "\(documentCount)", "realtime": "\(o.questionRealtime)", "lines": "\(lines.count)",
                                  "minutes": String(format: "%.1f", (lines.last?.end ?? 0) / 60), "warm": "\(options.warmRead != nil)",
                                  "detection": "\(options.detection)", "replayedHours": String(format: "%.4f", (lines.last?.end ?? 0) / 3600)]
                    if let first = closing.value { detail["closingTTFTSeconds"] = String(format: "%.3f", first) }
                    for (outcome, n) in Dictionary(grouping: rows, by: \.outcome).mapValues(\.count) { detail["n_" + outcome] = "\(n)" }
                    detail["shown"] = "\(rows.filter(\.shown).count)"
                    // The latency gate counts the checks that ran out of time (on the integrated model each one is energy spent for nothing).
                    let hours = max(0.01, (lines.last?.end ?? 0) / 3600)
                    detail["checkTimeoutsPerHour"] = String(format: "%.1f", Double(rows.filter { $0.outcome == "check_timeout" }.count) / hours)
                    return (Array(providers.chatModel.records.dropFirst(before)), detail)
                }
                write(trace)
                let url = dir.appendingPathComponent("questions.\(o.questionDetectOnly ? "none" : kind).jsonl")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                for r in rows {
                    struct Wire: Encodable { let meeting: String; let record: QuestionReplay.Record }
                    // One flat object per candidate: the meeting's name next to the record's own keys.
                    if var object = (try? JSONSerialization.jsonObject(with: encoder.encode(r))) as? [String: Any] {
                        object["meeting"] = name
                        object["provider"] = o.questionDetectOnly ? "none" : kind
                        if let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) { appendLine(d, to: url) }
                    }
                }
                await service.setRecording(false, meetingID: nil)
            }
            pair += 1
        }
    }

    /// Reads the files of a plain folder with no sandbox: the evaluation tool has no security-scoped bookmarks (a bookmark is the path as bytes).
    struct PlainFolderAccess: SourceAccessing {
        func makeBookmark(for url: URL) throws -> (data: Data, volumeUUID: String?) { (Data(url.path.utf8), nil) }
        func resolve(_ source: DocumentSource) -> SourceResolution {
            let path = String(decoding: source.bookmark, as: UTF8.self)
            return FileManager.default.fileExists(atPath: path) ? .resolved(url: URL(fileURLWithPath: path), renewed: nil) : .notFound
        }
        func begin(_ url: URL) -> Bool { false }
        func end(_ url: URL) {}
    }

    /// Every sentence of every transcript with its S1 score and the lines around it: the pool the labelling draws from.
    static func writeSentences(_ files: [URL], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path),
                  let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data), !transcript.passages.isEmpty else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let locale = transcript.language == "es" || name.hasPrefix("cdm") || name.hasPrefix("es_") ? "es-ES" : "en-US"
            var previous: QuestionCues.Previous?
            let lines = replayLines(transcript)
            for (i, line) in lines.enumerated() {
                let found = QuestionCues.scored(text: line.text, channel: .others, start: line.start, end: line.end, previous: previous, meetingLocale: locale)
                previous = QuestionCues.Previous(text: line.text, end: line.end)
                let context = (max(0, i - 3)..<min(lines.count, i + 3)).filter { $0 != i }.map { "[\(PromptText.clock(lines[$0].start))] \(lines[$0].text)" }
                for (index, sentence) in found.enumerated() {
                    let row = SentenceRow(meeting: name, line: line.id, channel: "others", t: line.start, end: line.end, index: index, text: sentence.text,
                                          score: (sentence.score * 1000).rounded() / 1000, cues: sentence.cues, mark: sentence.cues.contains("mark"),
                                          hasQuestionMark: sentence.text.contains("?") || sentence.text.contains("？"), context: context)
                    if let d = try? encoder.encode(row) { appendLine(d, to: url) }
                }
            }
        }
    }
}
