// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension LLMEvaluation {
    /// `llm-eval --tasks ask-retrieval --questions <file> [--after-meeting] [--ask old|new]`: EVALUATION ONLY, no language model call. Builds the
    /// meeting as `live-answer` does (up to the question's line while it records, or whole after it) and runs the keyword retrieval Ask runs on
    /// Apple's window (the question routed through the query translator, the passages of `MeetingStore.retrieve` within Apple's budget), then
    /// writes the ids of the transcript passages that would be sent, per question. The gold segments stay with the evaluation data: recall is
    /// computed from this file. Public transcripts only.
    static func runAskRetrieval(_ o: Options, store: LanguageModelStore, engine: LanguageModelEngine) async throws {
        guard let qURL = o.questions, let text = try? String(contentsOf: qURL, encoding: .utf8) else { throw MinutesEvaluation.Failure.noAnswer }
        var questions = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Question.self, from: Data($0.utf8)) }
        if let only = o.only { questions = questions.filter { $0.meeting.contains(only) } }
        let out = o.out.appendingPathComponent("retrieval")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let budget = RetrievalEvaluation.askBudget
        for setName in Set(questions.map(\.meeting)).sorted() {
            guard let data = FileManager.default.contents(atPath: o.sets.appendingPathComponent(setName + ".json").path),
                  let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data) else { continue }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-retrieval-eval-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let meetingStore = try MeetingStore(directory: directory, keyStore: MemoryKeyStore())
            let locale = Locale(identifier: transcript.language == "es" ? "es-ES" : "en-US")
            let meeting = try await meetingStore.startMeeting(at: Date(timeIntervalSince1970: 1_104_537_600), locale: locale, outputLocale: locale)
            let model = model("apple", store: store, greedy: o.greedy, engine: engine)
            let service = LLMService(store: meetingStore, providers: EvaluationProviders(model, searchModel: nil), searchDefaults: EvaluationDefaults.suite)
            await configureAsk(service, o)
            var passageOf: [Int64: Int64] = [:]
            var added = 0, clock = 0.0
            func append(until limit: Int) async throws {
                while added < limit {
                    let p = transcript.passages[added]
                    let start = p.start ?? clock
                    clock = start + 10
                    let line = p.speaker.map { "\($0): \(p.text)" } ?? p.text
                    let id = try await meetingStore.append(Segment(channel: .others, start: start, end: start + 8, text: line, isFinal: true), to: meeting)
                    passageOf[id] = p.id
                    added += 1
                }
            }
            if o.afterMeeting { try await append(until: transcript.passages.count) }
            for q in questions.filter({ $0.meeting == setName }).sorted(by: { $0.t_seg < $1.t_seg }) {
                if !o.afterMeeting { try await append(until: transcript.passages.prefix { $0.id <= q.t_seg }.count) }
                let language = OutputLanguage.detect([q.question], fallback: OutputLanguage(locale))
                let asked = Locale(identifier: language.identifier)
                let routed = await service.routedQuery(q.question, mode: .keyword, corpus: locale.language, locale: asked)
                let windowed = o.ask.contains(.windows)
                let found = try await meetingStore.retrieve(routed.text, queryVector: nil, within: meeting, limit: windowed ? o.askWindows.count : budget.askPassageLimit,
                                                      maxChars: budget.askPassageCharacters, locale: routed.locale, mode: .keyword, windows: windowed ? o.askWindows : nil)
                let sent = Array(Set(found.flatMap { $0.segments.compactMap { passageOf[$0.id] } })).sorted()
                let line: [String: Any] = ["case": q.qid, "sent": sent, "passages": found.count, "translated": routed.translated,
                                           "characters": found.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.text.count } }, "ask": o.ask.names]
                if let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) { appendLine(d, to: out.appendingPathComponent("retrieval.json")) }
            }
        }
    }
}
