// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Offline evaluation of task owners with and without speakers. No model runs: the model's answers are recorded in
/// `OwnerEvalCase` and played back through the real minutes pipeline (prompt, validation, owner rules, verification,
/// storage). It measures that pipeline, not a language model; see docs/OWNER_EVALUATION.md.
@Suite("Evaluation: task owners with and without speakers (fixtures)")
struct OwnerAccuracyEvalTests {
    struct Score: Equatable, CustomStringConvertible {
        var tasks = 0
        var correct = 0
        /// An owner was kept and it is not the right one.
        var wrong = 0
        /// No owner although the truth has one.
        var unassigned = 0
        /// Owners kept but marked "not confirmed" in the UI.
        var marked = 0
        /// The recorded answers as the model wrote them, before any rule of Swift touched them.
        var rawCorrect = 0
        /// Owners the rules of Swift turned from wrong or missing into right, and right ones they withheld (the label
        /// was doubtful) or replaced with a wrong one (the label was confident and wrong).
        var fixedByRules = 0, withheldByRules = 0, brokenByRules = 0
        /// Wrong owners the rules turned into "no owner".
        var preventedByRules = 0
        /// Gold tasks on a line with a doubtful label (a low score or crosstalk) whose recorded answer named an owner:
        /// where the rule "a doubtful label never gives a task" had something to decide, and what it did there.
        var doubtfulLines = 0, doubtfulWithheld = 0, doubtfulPrevented = 0
        /// Gold tasks the pipeline never stored (neither right nor a false alarm: reported on their own).
        var missing = 0
        /// Wrong owners that the interface marks "not confirmed".
        var wrongMarked = 0
        var plantedCaught = 0, planted = 0
        /// Gold tasks the evidence filter marked "to be confirmed" (the id of the meeting and the line), for the report.
        var flagged: [String] = []
        /// Right owners in the recorded answers that the rules replaced with a wrong one, for the report.
        var broken: [String] = []
        var falseAlarms = 0, faithful = 0

        var accuracy: Double { tasks == 0 ? 0 : Double(correct) / Double(tasks) }
        var description: String {
            "\(correct)/\(tasks) correct (\(rawCorrect)/\(tasks) before the rules of Swift), \(wrong) wrong, \(unassigned) unassigned, "
                + "\(marked) owners marked (\(wrongMarked) of them wrong), rules: +\(fixedByRules) fixed, -\(withheldByRules) withheld, -\(brokenByRules) broken, \(preventedByRules) wrong prevented, doubtful-label rule: \(doubtfulLines) lines, \(doubtfulWithheld) withheld, \(doubtfulPrevented) wrong prevented, \(missing) not stored; verification caught \(plantedCaught)/\(planted) planted errors with \(falseAlarms)/\(faithful) false alarms"
        }
        mutating func add(_ other: Score) {
            tasks += other.tasks; correct += other.correct; rawCorrect += other.rawCorrect; wrong += other.wrong; unassigned += other.unassigned
            marked += other.marked; fixedByRules += other.fixedByRules; withheldByRules += other.withheldByRules
            brokenByRules += other.brokenByRules; preventedByRules += other.preventedByRules
            doubtfulLines += other.doubtfulLines; doubtfulWithheld += other.doubtfulWithheld; doubtfulPrevented += other.doubtfulPrevented; missing += other.missing; wrongMarked += other.wrongMarked; plantedCaught += other.plantedCaught; planted += other.planted
            falseAlarms += other.falseAlarms; faithful += other.faithful; flagged += other.flagged; broken += other.broken
        }
    }

    private static let meetingDay: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
    }()

    /// The three arms. All three are played through the current pipeline and system prompt.
    enum Arm {
        /// Lines labeled "Me" / "Others"; the recorded answers often name an attendee for an unnamed "Others" line, which
        /// the current system prompt tells a model not to do.
        case baseline
        /// The same Me / Others prompt, with the answers a model that follows the current system prompt would give: every
        /// commitment of an unnamed "Others" line is left without an owner (derived mechanically from `baseline`).
        case conservative
        case speakers
        var withSpeakers: Bool { self == .speakers }
    }

    /// The `baseline` answers with every owner removed that neither the label the prompt shows nor the words of the line
    /// back: what a model that obeys "leave the owner null when you are not sure" answers to Me / Others lines. Such a
    /// model sees only "Me" and "Others", so it keeps "Me" on every line labeled "Me" (the user's channel), including a
    /// second voice in the room that the label cannot tell apart; it cannot use who really spoke.
    static func conservativeAnswers(_ item: OwnerEvalCase) -> [OwnerEvalCase.Output] {
        item.baseline.map { out in
            let line = item.lines[out.line]
            let own = out.owner == "Me" && item.speakers[line.speaker].channel == .me
            let named = out.owner.map { PromptText.containsNormalizedWords(TextKeys.norm(line.text), TextKeys.norm($0)) } ?? false
            return own || named ? out : OwnerEvalCase.Output(out.text, line: out.line, owner: nil, quote: out.quote, due: out.due)
        }
    }

    /// Runs one meeting through the real pipeline with the recorded answers of one arm.
    static func run(_ item: OwnerEvalCase, arm: Arm, extraction: MinutesExtraction = .legacy) async throws -> (score: Score, prompt: String) {
        let withSpeakers = arm.withSpeakers
        let f = try KnowledgeFixture()
        let store = f.store!
        let me = try await store.selfEntity()
        var entities: [String: Int64] = ["Me": me]
        for name in item.people { entities[name] = try await store.saveEntity(EntityDraft(kind: .person, name: name)) }
        let id = try await store.startMeeting(at: meetingDay, locale: Locale(identifier: item.locale))
        var segmentIDs: [Int64] = []
        for (index, line) in item.lines.enumerated() {
            let channel = item.speakers[line.speaker].channel
            segmentIDs.append(try await store.append(Segment(channel: channel, start: Double(index * 10), end: Double(index * 10 + 8),
                                                              text: line.text, isFinal: true), to: id))
        }
        try await store.endMeeting(id, at: meetingDay + 600)
        try await store.setMeetingEntities(id, role: .attendee, item.people.compactMap { entities[$0] })

        func ordinal(_ speaker: Int) -> Int { item.speakers[...speaker].filter { $0.channel == item.speakers[speaker].channel }.count }
        if withSpeakers {
            let drafts = item.speakers.indices.map { SpeakerDraft(channel: item.speakers[$0].channel, ordinal: ordinal($0)) }
            let assignments = item.lines.enumerated().map { index, line in
                let label = line.labeled ?? line.speaker
                return SegmentSpeakerAssignment(segmentID: segmentIDs[index], channel: item.speakers[label].channel,
                                         ordinal: ordinal(label), confidence: line.confidence, overlap: line.overlap)
            }
            try await store.finalizeSpeakers(meetingID: id, speakers: drafts, assignments: assignments)
            let stored = try await store.speakers(of: id)
            for (index, speaker) in item.speakers.enumerated() {
                guard let person = speaker.person, let entity = entities[person],
                      let row = stored.first(where: { $0.channel == speaker.channel && $0.ordinal == ordinal(index) }) else { continue }
                try await store.assignSpeaker(row.id, toEntity: entity)
            }
        }

        let answers: [OwnerEvalCase.Output]
        switch arm {
        case .baseline: answers = item.baseline
        case .conservative: answers = conservativeAnswers(item)
        case .speakers: answers = item.withSpeakers
        }
        let outputs = answers + item.planted
        let tasks: [[String: Any?]] = outputs.map { output in
            ["text": output.text, "owner": output.owner, "owner_id": nil, "due": output.due, "seg": segmentIDs[output.line],
             "quote": output.quote]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [
            "title": "t", "summary": "s", "topics": [String](), "decisions": [Any](), "tasks": tasks.map { $0.compactMapValues { $0 } },
            "entities": [Any](), "open_questions": [String](),
        ]), as: UTF8.self)
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(json) }
        let service = LLMService(store: store, providers: TestProviders(chat: chat))
        await service.setMinutesExtraction(extraction)
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        #expect(events.events.last?.outcome == .succeeded, "\(item.id)")
        let prompt = try #require(chat.calls.first).text

        var score = Score()
        let stored = try await store.tasks(id)
        let line = Dictionary(uniqueKeysWithValues: segmentIDs.enumerated().map { ($1, $0) })
        for gold in item.gold {
            score.tasks += 1
            let task = stored.first { $0.segmentID.flatMap { line[$0] } == gold.line }
            let expected = gold.owner.flatMap { entities[$0] }
            let right = task?.ownerID == expected
            if right { score.correct += 1 }
            else if task?.ownerID != nil { score.wrong += 1 }
            else { score.unassigned += 1 }
            let marked = task?.ownerID != nil && task?.ownerUncertain == true
            if marked { score.marked += 1 }
            if marked && !right { score.wrongMarked += 1 }
            let raw = outputs.first(where: { $0.line == gold.line }).map { $0.owner == gold.owner } ?? false
            if raw { score.rawCorrect += 1 }
            if right && !raw { score.fixedByRules += 1 }
            if raw && !right { if task?.ownerID == nil { score.withheldByRules += 1 } else { score.brokenByRules += 1; score.broken.append("\(item.id): \(item.lines[gold.line].text) -> \(task?.ownerName ?? "?") (gold \(gold.owner ?? "nobody"))") } }
            let answered = outputs.first(where: { $0.line == gold.line })?.owner
            if !raw, answered != nil, task?.ownerID == nil { score.preventedByRules += 1 }
            let label = item.lines[gold.line]
            if withSpeakers, answered != nil, label.overlap || label.confidence < SpeakerTag.lowConfidenceBelow {
                score.doubtfulLines += 1
                if raw && task?.ownerID == nil { score.doubtfulWithheld += 1 }
                if !raw && task?.ownerID == nil { score.doubtfulPrevented += 1 }
            }
            if let task { score.faithful += 1; if task.unconfirmed { score.falseAlarms += 1; score.flagged.append("\(item.id): \(item.lines[gold.line].text)") } } else { score.missing += 1 }
        }
        for plant in item.planted {
            score.planted += 1
            if stored.first(where: { $0.text == plant.text })?.unconfirmed == true { score.plantedCaught += 1 }
        }
        return (score, prompt)
    }

    static func total(_ arm: Arm, extraction: MinutesExtraction = .legacy) async throws -> Score {
        let withSpeakers = arm.withSpeakers
        var total = Score()
        for item in OwnerEvalCase.all {
            let (score, prompt) = try await run(item, arm: arm, extraction: extraction)
            // The fixtures must correspond to the prompt they stand for.
            let labeled = prompt.contains("(remote)] ") || prompt.contains("(remote)?] ") || prompt.contains("(in the room)] ")
            if withSpeakers {
                #expect(labeled && !prompt.contains("· Others]"), "\(item.id)")
                // A doubtful label (a low score, or crosstalk) shows "?" on its own line; a sure one does not.
                for (index, line) in item.lines.enumerated() {
                    let clock = PromptText.clock(Double(index * 10))
                    let shown = try #require(prompt.split(separator: "\n").first { $0.contains("· \(clock) · ") && $0.hasSuffix(line.text) }, "\(item.id) line \(index)")
                    let doubtful = line.overlap || line.confidence < SpeakerTag.lowConfidenceBelow
                    #expect(shown.contains("?] ") == doubtful, "\(item.id) line \(index): \(shown)")
                }
            }
            else { #expect(!labeled && prompt.contains("· Others]"), "\(item.id)") }
            total.add(score)
        }
        return total
    }

    @Test func speakersImproveTaskOwnerAccuracyOverMeAndOthers() async throws {
        let baseline = try await Self.total(.baseline)
        let conservative = try await Self.total(.conservative)
        let speakers = try await Self.total(.speakers)
        print("OWNER EVAL baseline (Me/Others): \(baseline)")
        print("OWNER EVAL conservative (Me/Others, unsure = no owner): \(conservative)")
        print("OWNER EVAL with speakers:       \(speakers)")
        // These are consistency checks of the fixtures with the code they exercise, not evidence about any model: the
        // gap between the arms comes from the recorded answers (see docs/OWNER_EVALUATION.md).
        #expect(speakers.accuracy > baseline.accuracy)
        #expect(speakers.wrong < baseline.wrong, "fewer tasks go to the wrong person")
        #expect(speakers.accuracy > conservative.accuracy, "speakers still help against a model that is careful with unnamed lines")
        // The numbers published in docs/OWNER_EVALUATION.md: a change that moves them must update the page.
        #expect(baseline == Score(tasks: 56, correct: 25, wrong: 15, unassigned: 16, marked: 15, rawCorrect: 25, preventedByRules: 1, wrongMarked: 14,
                                  plantedCaught: 4, planted: 4, falseAlarms: 0, faithful: 56))
        #expect(conservative == Score(tasks: 56, correct: 26, wrong: 1, unassigned: 29, marked: 0, rawCorrect: 26,
                                      plantedCaught: 4, planted: 4, falseAlarms: 0, faithful: 56))
        #expect(speakers == Score(tasks: 56, correct: 48, wrong: 5, unassigned: 3, marked: 3, rawCorrect: 47,
                                  fixedByRules: 3, withheldByRules: 2, brokenByRules: 0, preventedByRules: 2,
                                  doubtfulLines: 3, doubtfulWithheld: 2, doubtfulPrevented: 1, wrongMarked: 3,
                                  plantedCaught: 4, planted: 4, falseAlarms: 0, faithful: 56))
        if let page = Self.page {
            for number in ["25/56", "26/56", "48/56", "47/56", "15 wrong", "1 wrong", "5 wrong", "+3 fixed", "-2 withheld", "3 lines", "4/4"] { #expect(page.contains(number), "\(number) is in the page") }
        }
    }

    /// The same recorded answers through the extraction of this phase (the owner from the transcript, not from the model's label). The
    /// first block is the published baseline above; this one is reported next to it in docs/OWNER_EVALUATION.md.
    @Test func theNewOwnerRulesOnTheSameFixtures() async throws {
        let legacy = try await Self.total(.speakers)
        let baseline = try await Self.total(.baseline, extraction: .shipped)
        let speakers = try await Self.total(.speakers, extraction: .shipped)
        print("OWNER EVAL new extraction, Me/Others: \(baseline)")
        print("OWNER EVAL new extraction, with speakers: \(speakers)")
        for line in speakers.flagged { print("FLAGGED \(line)") }
        for line in speakers.broken { print("BROKEN \(line)") }
        #expect(speakers.brokenByRules <= legacy.brokenByRules, "the new rules do not break more right owners than the old ones")
        #expect(speakers.wrong <= legacy.wrong, "no more tasks go to the wrong person")
        #expect(speakers.accuracy >= baseline.accuracy)
        #expect(speakers.plantedCaught == speakers.planted)
        // The numbers published in docs/OWNER_EVALUATION.md ("The extraction of the development phase (owner from the transcript)"): a change that moves them must update the page.
        #expect(baseline.correct == 26 && baseline.wrong == 1 && baseline.unassigned == 29 && baseline.marked == 2 && baseline.wrongMarked == 0 && baseline.falseAlarms == 1)
        #expect(speakers.correct == 51 && speakers.wrong == 2 && speakers.unassigned == 3 && speakers.marked == 1 && speakers.wrongMarked == 0)
        #expect(speakers.fixedByRules == 6 && speakers.withheldByRules == 2 && speakers.brokenByRules == 0 && speakers.falseAlarms == 1 && speakers.planted == 4)
        if let page = Self.page {
            for number in ["51/56", "26/56", "2 wrong", "1 of 56", "6 fixed", "4/4"] { #expect(page.contains(number), "\(number) is in the page") }
        }
    }

    /// The evaluation page, found from this file's path (nil when the tests run away from the repository).
    private static var page: String? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent("docs/OWNER_EVALUATION.md"), encoding: .utf8)
    }

    @Test func theEvaluationCoversTheNineLanguages() {
        let languages = Set(OwnerEvalCase.all.map { String($0.locale.prefix(2)) })
        #expect(languages == ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"])
        #expect(OwnerEvalCase.all.allSatisfy { Set($0.gold.map(\.line)).count == $0.gold.count })
    }
}
