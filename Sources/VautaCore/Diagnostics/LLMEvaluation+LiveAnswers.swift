// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Darwin
import Foundation
import IOKit
internal import VautaMLX

extension LLMEvaluation {
    // MARK: Live answers

    struct Question: Decodable {
        let qid: String
        let meeting: String
        let t_seg: Int64
        let question: String
        let gold_answer: String?
        let gold_segments: [Int64]?
        let answerable: Bool?
        let category: String?
        let question_language: String?
    }

    static func appendLine(_ data: Data, to url: URL) {
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            h.write(Data("\n".utf8))
            try? h.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }

    /// Ask's harness for the evaluation, and the query translator the app always has (installed languages on this Mac only).
    static func configureAsk(_ service: LLMService, _ o: Options) async {
        await service.setAskHarness(o.ask)
        await service.setNoteHarness(o.notes)
        await service.setQueryTranslation(o.ask.contains(.queryTranslation) ? AppleTranslationBackend() : nil)
    }

    static func runAnswers(_ o: Options, store: LanguageModelStore, engine: LanguageModelEngine, write: (Trace) -> Void) async throws {
        guard let qURL = o.questions, let text = try? String(contentsOf: qURL, encoding: .utf8) else { throw MinutesEvaluation.Failure.noAnswer }
        var questions = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Question.self, from: Data($0.utf8)) }
        if let only = o.only { questions = questions.filter { $0.meeting.contains(only) } }
        if let m = o.maxItems { questions = Array(questions.prefix(m)) }
        let answersDir = o.out.appendingPathComponent("answers")
        try FileManager.default.createDirectory(at: answersDir, withIntermediateDirectories: true)
        var pair = 0
        for setName in Set(questions.map(\.meeting)).sorted() {
            guard let data = FileManager.default.contents(atPath: o.sets.appendingPathComponent(setName + ".json").path),
                  let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data) else { continue }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-answer-eval-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let meetingStore = try MeetingStore(directory: directory, keyStore: MemoryKeyStore())
            let locale = Locale(identifier: transcript.language == "es" ? "es-ES" : "en-US")
            let date = Date(timeIntervalSince1970: 1_104_537_600)
            let meeting = try await meetingStore.startMeeting(at: date, locale: locale, outputLocale: locale)
            var services: [String: (LLMService, EvaluationProviders, EvaluationModel)] = [:]
            for kind in o.providers {
                let m = model(kind, store: store, greedy: o.greedy, engine: engine)
                let providers = EvaluationProviders(m, searchModel: o.searchModel)
                let service = LLMService(store: meetingStore, providers: providers, searchDefaults: EvaluationDefaults.suite)   // never .standard
                await service.forgetSearchModelCoverage()   // the suite is shared by every set of the run: no marker from an earlier one
                await service.setAnswerGuards(o.guards)
                await configureAsk(service, o)
                // The questions are asked while the meeting is "recording", as the app asks them: the live rules, caps and schema apply.
                await service.setRecording(true, meetingID: meeting)
                services[kind] = (service, providers, m)
            }
            var added = 0
            var passageOf: [Int64: Int64] = [:]
            var clock = 0.0
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
            if o.afterMeeting {
                // The whole meeting is read while it records; then the recording stops and the questions are about a finished meeting.
                try await append(until: transcript.passages.count)
                if o.warm, let (service, _, _) = services["integrated"] { await service.readMeetingNow(meeting) }
                for (_, (service, _, _)) in services { await service.setRecording(false, meetingID: meeting) }
            }
            for q in questions.filter({ $0.meeting == setName }).sorted(by: { $0.t_seg < $1.t_seg }) {
                // The meeting as it was when the question was asked: only the segments up to t_seg.
                // With `--warm` the integrated model has read the meeting up to a few segments before the question (the reading runs in the
                // background of a real recording, and the last stretch is unread when the question comes).
                let upTo = o.afterMeeting ? transcript.passages.count : transcript.passages.prefix { $0.id <= q.t_seg }.count
                let unread = o.warm && !o.afterMeeting ? min(3, upTo) : 0
                try await append(until: upTo - unread)
                if o.warm, !o.afterMeeting, let (service, _, _) = services["integrated"] { await service.readMeetingNow(meeting) }
                try await append(until: upTo)
                let (waited, _) = await waitForQuiet(o)
                let sequence = order(pair, o.providers)
                for kind in sequence {
                    guard let (service, providers, m) = services[kind] else { continue }
                    var answerText = ""
                    var cited: [Int64] = []
                    var sentPassages: [Int64] = []
                    let before = providers.chatModel.records.count
                    let trace = await measure(task: "live-answer", provider: kind, item: q.qid, pair: pair, order: sequence[0] == o.providers[0] ? "AB" : "BA",
                                              model: m, waited: waited, options: o) {
                        let r = try await service.ask(q.question, meetingID: meeting)
                        sentPassages = Array(Set(r.sent.keys.compactMap { passageOf[$0] })).sorted()
                        answerText = r.answer.answer
                        let verified = r.answer.claims.filter(\.verified).count
                        cited = Array(Set(r.answer.claims.flatMap(\.citations).compactMap { passageOf[$0] })).sorted()
                        let gold = Set(q.gold_segments ?? [])
                        let hit = Set(cited).intersection(gold).count
                        return (Array(providers.chatModel.records.dropFirst(before)),
                                ["claims": "\(r.answer.claims.count)", "verifiedClaims": "\(verified)", "cited": cited.map(String.init).joined(separator: ","),
                                 "citationRecall": gold.isEmpty ? "" : String(format: "%.3f", Double(hit) / Double(gold.count)),
                                 "citationPrecision": cited.isEmpty ? "" : String(format: "%.3f", Double(hit) / Double(cited.count)),
                                 "found": "\(r.answer.found)", "refused": "\(!r.answer.found && !r.answer.withheldAnAnswer)",
                                 "refusedWithAnswer": "\(!r.answer.found && r.answer.withheldAnAnswer)", "cutShort": "\(r.answer.cutShort)",
                                 "unverified": "\(r.answer.isUnverified)", "kind": "\(r.answer.kind)", "guards": o.guards.names, "warm": "\(o.warm)",
                                 "reanchored": "\(r.answer.claims.filter { $0.reanchoredFrom != nil }.count)",
                                 "noEvidence": "\(r.answer.claims.isEmpty)", "answerable": "\(q.answerable ?? true)", "category": q.category ?? "",
                                 "language": q.question_language ?? "", "answerChars": "\(answerText.count)", "tSeg": "\(q.t_seg)",
                                 "warmPrefix": "\(providers.chatModel.records.dropFirst(before).first.map { $0.cachedTokens > 0 } ?? false)",
                                 "ask": o.ask.names, "sent": sentPassages.map(String.init).joined(separator: ",")])
                    }
                    write(trace)
                    // The model's reply as it came, to see what the checks were given (the sets are public transcripts).
                    let line: [String: Any] = ["case": q.qid, "answer": answerText, "citations": cited, "sent": sentPassages, "reply": providers.chatModel.last ?? ""]
                    if let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) { appendLine(d, to: answersDir.appendingPathComponent("answers.\(kind).jsonl")) }
                }
                pair += 1
            }
        }
    }
}
