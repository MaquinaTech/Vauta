// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The `actions` task of `llm-eval` on an invented meeting: the deterministic arms and the replay scenarios need no model and no EventKit.
@Suite("Actions: the evaluation task")
struct ActionsEvaluationTests {
    static let transcript = BriefEvaluationTests.transcript([
        "Okay, first the supplier change and the shell material.", "Ana, can you send the revised budget before Friday?", "Yes, I will send it by Friday.",
        "Luis, please book the factory visit.", "Sure, I will book it.", "Good. Let's meet again on October 21 at 10:30 to close the supplier change.", "Perfect, see you then.",
    ])
    static let minutes = """
        {"case": "m1", "summary": "The team discussed the supplier change.", "decisions": [{"text": "Keep the C-shaped shell"}], "tasks": [{"text": "Send the revised budget", "owner": "Speaker 2", "due": "2026-10-16"}, {"text": "Book the factory visit", "owner": "Speaker 4", "due": null}, {"text": "Review the supplier contract", "owner": null, "due": "2026-10-30"}], "open_questions": ["Who signs off the change?"]}
        """
    static let fixture = """
        {"meeting": "m1", "started_at": "2026-10-12T10:00:00+02:00", "time_zone": "Europe/Madrid",
         "attendees": [{"name": "Ana López", "email": "ana@example.org"}, {"name": "Luis Pérez", "email": "luis@elsewhere.example"}],
         "you": {"name": "Maya", "email": "maya@example.org"},
         "speakers": {"Speaker 2": "Ana López", "Speaker 4": "Luis Pérez"},
         "closing": ["Same time in two weeks, then.", "Agreed."],
         "existing_reminders": ["Book the factory visit", "Water the plants"]}
        """

    static func seeded(_ directory: URL) async throws -> ActionsEvaluation.Seeded {
        let transcript = try JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: Data(Self.transcript.utf8))
        let minutes = try JSONDecoder().decode(BriefEvaluation.StoredMinutes.self, from: Data(Self.minutes.utf8))
        let fixture = try JSONDecoder().decode(ActionsEvaluation.Fixture.self, from: Data(Self.fixture.utf8))
        return try await ActionsEvaluation.seed(name: "m1", transcript: transcript, fixture: fixture, minutes: minutes, directory: directory)
    }

    @Test func theReplayScenariosCreateNoDuplicateAndUndoOnlyVautasItems() async throws {
        let folder = try BriefEvaluationTests.Folder()
        let seeded = try await Self.seeded(folder.url)
        #expect(seeded.tasks.count == 3 && seeded.tasks.first { $0.text.hasPrefix("Send") }?.dueDay?.string == "2026-10-16")
        let fixture = try JSONDecoder().decode(ActionsEvaluation.Fixture.self, from: Data(Self.fixture.utf8))
        let report = await ActionsEvaluation.replay(seeded: seeded, fixture: fixture, directory: folder.url)
        #expect(report.failures == 0, "\(report.detail)")
        #expect(report.detail["duplicatesCreated"] == "0" && report.detail["rewriteTwins"] == "0" && report.detail["doubleAdded"] == "0")
        #expect(report.detail["usedExisting"] == "1", "the look-alike in the list was offered and taken, not duplicated")
        #expect(report.detail["added"] == "2" && report.detail["writes"] == "2", "two tasks written; the third was already in the list")
        #expect(report.detail["crashAdopted"] == "true" && report.detail["crashWrites"] == "1")
        #expect(report.detail["dueDayMismatches"] == "0" && report.detail["dueDayChecked"] == "2")
        #expect(report.detail["orphanCaught"] == "true")
        #expect(report.detail["undoWrongRemovals"] == "0" && report.detail["undoForeignKept"] == "true" && report.detail["undoRemoved"] == report.detail["undoCreated"])
    }

    @Test func theDeterministicArmsWriteBlindlyLabelledOutputsAndTheTracerIsClean() async throws {
        let folder = try BriefEvaluationTests.Folder()
        let out = folder.url.appendingPathComponent("out")
        for sub in ["emails", "followups"] { try FileManager.default.createDirectory(at: out.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let transcript = try JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: Data(Self.transcript.utf8))
        let minutes = try JSONDecoder().decode(BriefEvaluation.StoredMinutes.self, from: Data(Self.minutes.utf8))
        let fixture = try JSONDecoder().decode(ActionsEvaluation.Fixture.self, from: Data(Self.fixture.utf8))
        var labels = ActionsEvaluation.Labels()
        var details: [ActionsEvaluation.Kind: [String: String]] = [:]
        for kind in [ActionsEvaluation.Kind.et1, .eto, .fd, .fdx, .rp] {
            let label = labels.label(meeting: "m1", kind: kind, provider: "apple")
            var options = LLMEvaluation.Options(sets: folder.url, out: out)
            options.actions.nameSpeakers = true
            let result = try await ActionsEvaluation.runArm(kind, provider: "apple", name: "m1", label: label, transcript: transcript, fixture: fixture,
                                                            minutes: minutes, model: .apple, options: options)
            #expect(result.calls.isEmpty, "\(kind): no model was called")
            details[kind] = result.detail
        }
        let emails = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("emails").path).sorted()
        let followups = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("followups").path).sorted()
        #expect(emails.count == 3 && followups.count == 2, "one email, two per-owner emails; two follow-up files")
        for name in emails + followups {
            #expect(!["ET1", "ETO", "FD", "FDX", "EBL", "apple"].contains { name.contains($0) }, "\(name) names no arm")
        }
        #expect(details[.et1]?["tracerViolations"] == "0" && details[.eto]?["tracerViolations"] == "0" && details[.eto]?["drafts"] == "2")
        let labelled = Set(labels.key.keys)
        #expect(labelled.count == 5 && labels.key.values.allSatisfy { $0["arm"] != nil })
        // The detector found the agreed day, from the closing lines the fixture added.
        let fd = try String(contentsOf: out.appendingPathComponent("followups/m1.\(labels.key.first { $0.value["arm"] == "FD" }!.key).json"), encoding: .utf8)
        #expect(fd.hasPrefix("{\"candidates\":["), "the detector as the app runs it reads the last tenth: a 9-line meeting has one line of it")
        let fdx = try String(contentsOf: out.appendingPathComponent("followups/m1.\(labels.key.first { $0.value["arm"] == "FDX" }!.key).json"), encoding: .utf8)
        #expect(fdx.contains("\"2026-10-21\"") && fdx.contains("630") && fdx.contains("\"2026-10-26\""), "reading every segment finds both mentions")
        let email = try String(contentsOf: out.appendingPathComponent("emails/m1.\(labels.key.first { $0.value["arm"] == "ET1" }!.key).txt"), encoding: .utf8)
        #expect(email.contains("Ana López: Send the revised budget") && email.contains("Luis Pérez: Book the factory visit") && email.contains("Review the supplier contract"))
        #expect(email.contains("Friday, October 16") && !email.contains("Speaker"))
    }

    @Test func theBaselineAnswerIsReadLeniently() {
        #expect(ActionsEvaluation.parseNextMeeting(#"Sure! {"next_meeting": {"date": "2026-10-21", "time": "10:30"}} Hope it helps."#)?.minute == 630)
        #expect(ActionsEvaluation.parseNextMeeting(#"{"next_meeting": {"date": "2026-10-21", "time": null}}"#)?.day.string == "2026-10-21")
        #expect(ActionsEvaluation.parseNextMeeting(#"{"next_meeting": null}"#) == nil)
        #expect(ActionsEvaluation.parseNextMeeting(#"{"next_meeting": {"date": "2026-02-30"}}"#) == nil, "not a date")
        #expect(ActionsEvaluation.parseNextMeeting("no json at all") == nil)
        #expect(ActionsEvaluation.parseNextMeeting(#"{"next_meeting": {"date": "2026-10-21", "time": "25:99"}}"#)?.minute == nil)
    }

    @Test func armNamesAreParsedAndTheModelOnlyLoadsForTheBaselines() {
        #expect(ActionsEvaluation.Options.kinds(named: ["et1", "FD", "rp"]) == [.et1, .fd, .rp])
        #expect(ActionsEvaluation.Options.kinds(named: ["ET1", "nope"]) == nil)
        var options = ActionsEvaluation.Options()
        options.kinds = [.et1, .eto, .fd, .fdx, .rp]
        #expect(!options.needsModel)
        options.kinds.append(.ebl)
        #expect(options.needsModel)
    }

    @Test func fixturesAreHashedAndAnUnreadableOneIsAnError() throws {
        let folder = try BriefEvaluationTests.Folder()
        try folder.write("m1.actions.json", Self.fixture)
        var options = ActionsEvaluation.Options()
        options.fixtures = folder.url
        let loaded = try ActionsEvaluation.loadFixtures(options)
        #expect(loaded.fixtures["m1"]?.attendees.count == 2 && loaded.manifest.hasSuffix("  m1.actions.json\n") && loaded.manifest.count == 64 + 2 + "m1.actions.json".count + 1)
        try folder.write("bad.actions.json", "{")
        #expect(throws: ActionsEvaluation.Failure.self) { try ActionsEvaluation.loadFixtures(options) }
    }
}
