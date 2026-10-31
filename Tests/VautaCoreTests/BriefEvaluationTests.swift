// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The `brief` task of `llm-eval` on invented sets: a keyword arm needs no model, so the whole path from the fixtures to the rendered brief runs here.
@Suite("Brief: the evaluation task", .serialized)   // one throwaway store at a time, so the leftover check sees only its own
struct BriefEvaluationTests {
    final class Folder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-brief-eval-tests-\(UUID().uuidString)", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
        func write(_ name: String, _ text: String) throws { try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    }

    static func transcript(_ lines: [String]) -> String {
        let passages = lines.enumerated().map { i, text in #"{"id": \#(i + 1), "start": \#(i * 10), "speaker": "Speaker \#(i % 2 + 1) (remote)", "text": "\#(text)"}"# }
        return #"{"meeting": "X", "language": "en", "passages": [\#(passages.joined(separator: ","))]}"#
    }

    static let fixture = """
        {"series": "S1", "language": "en", "split": "dev", "briefed": "S1d", "earlier": ["S1b", "S1c"],
         "speakers": {"Speaker 1": "Ana López"},
         "event": {"title": "Supplier review", "attendees": [{"name": "Ana López", "email": "ana@example.com"}], "new_attendees": [{"name": "Luis Pérez", "email": null}],
                   "service": null, "invitation_notes": "Agenda:\\n- Shell material and tooling quote"},
         "reminders": [{"id": "r1", "title": "Call Ana López about the shell material quote", "due_days": -1, "list": "Work", "relevant": true},
                       {"id": "r2", "title": "Buy milk", "due_days": null, "list": "Work", "relevant": false},
                       {"id": "r3", "title": "Pay the supplier invoice for the shell material", "due_days": 2, "list": "Work", "relevant": false}],
         "notes": [{"name": "tooling.md", "text": "Tooling quote for the shell material from the supplier: three offers are open.", "relevant": true},
                   {"name": "garden.md", "text": "Plant the tomatoes in May and water them twice a week.", "relevant": false}],
         "documents": [{"name": "budget.md", "text": "Supplier change budget: the shell material costs 48.200 euros in the first quarter.", "relevant": true}]}
        """

    static let minutes = """
        {"case": "S1b", "summary": "The team discussed the old supplier.", "decisions": [], "tasks": [], "open_questions": []}
        {"case": "S1c", "summary": "The team compared the supplier change and the shell material. A third supplier was dropped.", "decisions": [{"text": "Keep the C-shaped shell"}], "tasks": [{"text": "Send the revised budget for the supplier change", "owner": "Speaker 1", "due": null}, {"text": "Book the factory visit", "owner": null, "due": null}], "open_questions": ["Who signs off the supplier change?"]}
        """

    static func rig() throws -> (sets: Folder, fixtures: Folder, options: LLMEvaluation.Options) {
        let sets = try Folder(), fixtures = try Folder()
        try sets.write("S1b.json", transcript(["We talked about the old supplier contract.", "It ends in March."]))
        try sets.write("S1c.json", transcript(["We still need to decide who signs off the supplier change.", "The shell material stays open until legal answers.", "Send the revised budget for the supplier change."]))
        try fixtures.write("S1.brief.json", fixture)
        try sets.write("minutes_integrated.jsonl", minutes)
        var options = LLMEvaluation.Options(sets: sets.url, out: sets.url.appendingPathComponent("out"))
        options.brief.fixtures = fixtures.url
        options.brief.minutes["integrated"] = sets.url.appendingPathComponent("minutes_integrated.jsonl")
        return (sets, fixtures, options)
    }

    @Test func fixturesAreReadHashedAndFilteredBySplit() throws {
        let r = try Self.rig()
        let loaded = try BriefEvaluation.loadFixtures(r.options.brief)
        #expect(loaded.count == 1 && loaded[0].fixture.series == "S1" && loaded[0].fixture.earlier == ["S1b", "S1c"] && loaded[0].file == "S1.brief.json")
        #expect(loaded[0].hash.count == 64)
        var test = r.options.brief
        test.split = "test"
        #expect(throws: BriefEvaluation.Failure.self) { try BriefEvaluation.loadFixtures(test) }
        #expect(throws: BriefEvaluation.Failure.self) { try BriefEvaluation.loadFixtures(BriefEvaluation.Options()) }
        try r.fixtures.write("bad.brief.json", "{not json")
        #expect(throws: BriefEvaluation.Failure.self) { try BriefEvaluation.loadFixtures(r.options.brief) }
    }

    @Test func theArmsAreTheOnesOfTheDesign() {
        #expect(BriefEvaluation.Arm.all.map(\.name) == ["K0", "S0", "KA", "SA", "KG", "SG", "BLA", "BLG"])
        #expect(BriefEvaluation.Arm.named(["k0", "BL", "SG"])?.map(\.name) == ["K0", "BLA", "SG"])
        #expect(BriefEvaluation.Arm.named(["K0", "nonsense"]) == nil)
        let k0 = BriefEvaluation.Arm.all[0], sg = BriefEvaluation.Arm.all[5]
        #expect(!k0.semantic && k0.provider == nil && sg.semantic && sg.provider == "integrated")
        var options = BriefEvaluation.Options()
        options.arms = [k0]
        #expect(!options.needsIntegrated)
        options.arms = [sg]
        #expect(options.needsIntegrated)
    }

    @Test func aKeywordBriefIsBuiltFromTheEarlierMeetingsAndTheFixtures() async throws {
        let r = try Self.rig()
        let fixture = try #require(try BriefEvaluation.loadFixtures(r.options.brief).first?.fixture)
        let minutes = BriefEvaluation.loadMinutes(r.options.brief.minutes["integrated"])
        #expect(minutes.keys.sorted() == ["S1b", "S1c"])
        let run = try await BriefEvaluation.runArm(BriefEvaluation.Arm.all[0], fixture: fixture, options: r.options, model: .apple, minutes: ["integrated": minutes])
        let text = run.text
        #expect(text.contains("Meeting: Supplier review"))
        #expect(text.contains("Last time:") && text.contains("Decision: Keep the C-shaped shell"))
        #expect(text.contains("Open task: Send the revised budget for the supplier change (Ana López)"))
        #expect(text.contains("Open question: Who signs off the supplier change?"))
        #expect(text.contains("Luis Pérez (no earlier meetings)") && text.contains("Ana López (last met"))
        #expect(text.contains("Note: tooling.md") && !text.contains("garden.md"), "an exported note is badged \"Note\"; a distractor stays out")
        #expect(text.contains("File: budget.md"))
        #expect(text.contains("Call Ana López about the shell material quote") && !text.contains("Buy milk"))
        #expect(text.contains("From the invitation:") && text.contains("Shell material and tooling quote"))
        #expect(!text.contains("Suggested agenda"), "the arms without a model have none")
        #expect(run.detail["linksInvalid"] == "0" && run.detail["wrongAttribution"] == "0" && run.detail["inventedHistory"] == "false")
        #expect(run.detail["deterministic"] == "true" && run.detail["mode"] == "keyword")
        #expect(run.calls.isEmpty, "no model was called")
        let distractors = Int(run.detail["distractorsShown"] ?? "") ?? 99
        #expect(distractors <= 1, "at most one distractor on average")
    }

    @Test func aFirstMeetingInventsNoHistory() async throws {
        let r = try Self.rig()
        var fixture = try #require(try BriefEvaluation.loadFixtures(r.options.brief).first?.fixture)
        let data = try JSONSerialization.jsonObject(with: Data(Self.fixture.utf8)) as! [String: Any]
        var changed = data
        changed["earlier"] = [String]()
        let decoded = try JSONDecoder().decode(BriefEvaluation.Fixture.self, from: JSONSerialization.data(withJSONObject: changed))
        fixture = decoded
        let run = try await BriefEvaluation.runArm(BriefEvaluation.Arm.all[0], fixture: fixture, options: r.options, model: .apple, minutes: [:])
        #expect(run.detail["inventedHistory"] == "false" && !run.text.contains("Last time:") && !run.text.contains("Open tasks:") && !run.text.contains("Related meetings:"))
        #expect(run.text.contains("no earlier meetings"))
    }

    @Test func theRenderedBriefNamesNoArmAndTheStoreIsNotKept() async throws {
        let r = try Self.rig()
        let fixture = try #require(try BriefEvaluation.loadFixtures(r.options.brief).first?.fixture)
        let minutes = BriefEvaluation.loadMinutes(r.options.brief.minutes["integrated"])
        func stores() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("vauta-brief-eval-") && !$0.contains("tests") } ?? [])
        }
        let before = stores()   // a run that crashed earlier may have left one
        let one = try await BriefEvaluation.runArm(BriefEvaluation.Arm.all[0], fixture: fixture, options: r.options, model: .apple, minutes: ["integrated": minutes])
        let two = try await BriefEvaluation.runArm(BriefEvaluation.Arm.all[0], fixture: fixture, options: r.options, model: .apple, minutes: ["integrated": minutes])
        #expect(one.text == two.text && one.detail["digest"] == two.detail["digest"], "a replay gives the same brief")
        for word in ["K0", "keyword", "apple", "integrated", "cosine"] { #expect(!one.text.lowercased().contains(word.lowercased()), "\(word) would give the arm away") }
        #expect(stores().subtracting(before).isEmpty, "the throwaway stores are removed, with nothing written after")
    }

    @Test func theDayPrintedInTheBriefIsCheckedAgainstTheStoredMinutesInAnyTimeZone() throws {
        let line = #"{"case": "S1c", "summary": "x", "decisions": [], "tasks": [{"text": "Send the budget", "owner": null, "due": "2005-05-03"}], "open_questions": []}"#
        let minutes = [try JSONDecoder().decode(BriefEvaluation.StoredMinutes.self, from: Data(line.utf8))]
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let stored = try #require(PromptText.parseDay("2005-05-03", reference: la.date(from: DateComponents(year: 2005, month: 5, day: 10)) ?? .now, timeZone: la.timeZone))
        var item = BriefItem(id: "b1", kind: .task, text: "Send the budget")
        item.due = stored
        let snapshot = BriefSnapshot(occurrence: BriefOccurrence(identifier: "e", start: stored), title: "T", start: stored, end: stored, service: nil, seriesName: nil,
                                     mode: .keyword, relatedSkipped: false, sections: [BriefSection(kind: .openTasks, items: [item])])
        let right = BriefEvaluation.render(snapshot, calendar: la)
        #expect(right.contains("due 2005-05-03"))
        #expect(BriefEvaluation.printedDueMismatch(item, rendered: right, minutes: minutes) == 0)
        var samoa = la
        samoa.timeZone = TimeZone(identifier: "Pacific/Pago_Pago") ?? .current
        let shifted = BriefEvaluation.render(snapshot, calendar: samoa)
        #expect(shifted.contains("due 2005-05-02"), "a formatter in another zone prints another day")
        #expect(BriefEvaluation.printedDueMismatch(item, rendered: shifted, minutes: minutes) == 1, "and the check against the minutes catches it")
        #expect(BriefEvaluation.independentDay(stored, la) == "2005-05-03")
    }
}
