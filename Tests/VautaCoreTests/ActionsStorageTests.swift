// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Post-meeting actions: migration 28, the ledger, and "acting makes it yours".
@Suite("Actions: storage and ledger")
struct ActionsStorageTests {
    static func minutes(_ segs: [MeetingStore.StoredSegment], tasks: [(String, Int)], due: Date? = nil, dueDay: DueDay? = nil) -> ValidatedMinutes {
        var m = ValidatedMinutes()
        m.title = "Plan"
        m.summary = "Summary"
        m.tasks = tasks.map { .init(text: $0.0, owner: nil, due: due, segment: segs[$0.1].id, t: segs[$0.1].start, dueDay: dueDay) }
        return m
    }

    // MARK: Migration 28

    @Test func migration28IsANewEntryAndKeepsThePublishedOnes() throws {
        #expect(Schema.currentVersion >= 28)
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: 27)
        let before = try db.query("SELECT type, name, ifnull(sql, '') FROM sqlite_schema ORDER BY type, name").map { [$0.string(0), $0.string(1), $0.string(2)] }
        try Schema.migrate(db, upTo: 28)
        #expect(try Schema.version(of: db) == 28)
        let tasks = try db.query("SELECT name FROM pragma_table_info('tasks')").map { $0.string(0) }
        #expect(tasks.last == "due_day")
        let meetings = try db.query("SELECT name FROM pragma_table_info('meetings')").map { $0.string(0) }
        #expect(meetings.suffix(2) == ["time_zone", "follow_ups_recipe"])
        #expect(try db.query("SELECT name FROM pragma_table_info('created_actions')").map { $0.string(0) } ==
                ["id", "target", "src_kind", "src_id", "meeting_id", "ek_id", "ek_external_id", "container_id", "title_hash", "state", "written_at", "updated_at", "due_basis"])
        #expect(try db.query("SELECT name FROM pragma_table_info('follow_ups')").count == 13)
        // The schema guard accepts the image (it equals the migrations' own), so a backup made by this version restores.
        #expect(throws: Never.self) { try BackupSchemaGuard.validate(db) }
        // Nothing that existed at 27 was edited: every earlier object is still there with the same SQL, except the two altered tables.
        let after = try db.query("SELECT type, name, ifnull(sql, '') FROM sqlite_schema ORDER BY type, name").map { [$0.string(0), $0.string(1), $0.string(2)] }
        let changed = before.filter { row in !after.contains(row) }.map { $0[1] }
        #expect(Set(changed) == ["tasks", "meetings"], "only ALTER TABLE rewrote earlier SQL")
    }

    @Test func dueDayIsBackfilledFromDueInThisMacsZone() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: 27)
        try db.query("INSERT INTO meetings(started_at) VALUES (1)")
        let due = DueDay(year: 2026, month: 10, day: 16)!.startOfDay(in: .current)
        try db.query("INSERT INTO tasks(meeting_id, text, due, source, created_at) VALUES (1, 'a', ?, 'llm', 1)", [.real(due.timeIntervalSince1970)])
        try db.query("INSERT INTO tasks(meeting_id, text, source, created_at) VALUES (1, 'b', 'llm', 1)")
        try Schema.migrate(db)
        let days = try db.query("SELECT due_day FROM tasks ORDER BY id").map { $0.optionalString(0) }
        #expect(days == ["2026-10-16", nil])
    }

    @Test func aMeetingKeepsTheZoneItWasRecordedIn() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.store.startMeeting(at: .now, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(try await f.store.meetingTimeZone(id)?.identifier == "Asia/Tokyo")
        try await f.store.endMeeting(id, at: .now)
        let older = try await f.meeting(["x"])
        #expect(try await f.store.meetingTimeZone(older) != nil)
        try await f.store.executeForTest("UPDATE meetings SET time_zone = NULL WHERE id = ?", [.integer(older)])
        #expect(try await f.store.meetingTimeZone(older) == nil, "older meetings have none")
    }

    // MARK: due_day

    @Test func dueDayIsStoredFromTheMinutesDayAndNotRecomputed() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Ana prepara la demo"])
        let segs = try await s.segments(of: m)
        // The minutes wrote 2026-10-16; a Date at the start of that day in Madrid is the evening of the 15th in Los Angeles.
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        let due = DueDay(year: 2026, month: 10, day: 16)!.startOfDay(in: madrid)
        try await s.applyMinutes(Self.minutes(segs, tasks: [("Preparar la demo", 0)], due: due, dueDay: DueDay("2026-10-16")), to: m)
        let task = try #require(try await s.tasks(m).first)
        #expect(task.dueDay?.string == "2026-10-16")
        #expect(DueDay.containing(due, in: TimeZone(identifier: "America/Los_Angeles")!).string == "2026-10-15", "the Date alone would have shifted")
    }

    @Test func addingAndEditingATaskKeepsDueDayWithItsDue() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["x"])
        let id = try await s.addTask(m, text: "Send it", due: Date(timeIntervalSince1970: 1_792_000_000))
        var task = try #require(try await s.tasks(m).first { $0.id == id })
        #expect(task.dueDay == DueDay.containing(Date(timeIntervalSince1970: 1_792_000_000), in: .current))
        // Editing something else leaves the day alone; changing the due date changes it.
        task.text = "Send it today"
        try await s.updateTask(task)
        #expect(try await s.tasks(m).first?.dueDay == task.dueDay)
        task.due = DueDay(year: 2027, month: 1, day: 5)!.startOfDay(in: .current)
        try await s.updateTask(task)
        #expect(try await s.tasks(m).first?.dueDay?.string == "2027-01-05")
        task.due = nil
        try await s.updateTask(task)
        let cleared = try #require(try await s.tasks(m).first)
        #expect(cleared.due == nil)
    }

    // MARK: The ledger

    @Test func aSecondLiveRowIsRejectedIncludingAWritingOne() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Ana prepara la demo"])
        let segs = try await s.segments(of: m)
        try await s.applyMinutes(Self.minutes(segs, tasks: [("Preparar la demo", 0)]), to: m)
        let task = try #require(try await s.tasks(m).first)
        let first = try await s.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: "L", titleHash: "h")
        await #expect(throws: ActionLedgerError.self) { _ = try await s.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: "L", titleHash: "h") }
        // The unique index itself says no, whatever the code does.
        await #expect(throws: (any Error).self) {
            try await s.executeForTest("INSERT INTO created_actions(target, src_kind, src_id, title_hash, state, written_at, updated_at) VALUES ('reminder', 'task', ?, 'x', 'created', 1, 1)",
                                       [.integer(task.id)])
        }
        // Another target for the same task is fine, and a removed row frees the slot.
        _ = try await s.beginAction(target: .event, source: .task, sourceID: task.id, containerID: "C", titleHash: "h")
        try await s.completeAction(first.action.id, itemID: "a", externalID: "e")
        try await s.setActionState(first.action.id, .removed)
        _ = try await s.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: "L", titleHash: "h")
    }

    @Test func deletingATaskOrphansItsLiveRowAndTheRowSurvives() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Ana prepara la demo"])
        let segs = try await s.segments(of: m)
        try await s.applyMinutes(Self.minutes(segs, tasks: [("Preparar la demo", 0)]), to: m)
        let task = try #require(try await s.tasks(m).first)
        let row = try await s.recordLinked(target: .reminder, source: .task, sourceID: task.id, containerID: "L", itemID: "r1", externalID: "e1", titleHash: "h")
        try await s.deleteTask(task.id)
        let after = try #require(try await s.action(row.id))
        #expect(after.state == .orphaned && after.itemID == "r1", "the reminder still exists and still counts")
        let found = try await s.orphanedAction(meetingID: m, target: .reminder, titleHash: "h")
        #expect(found?.id == row.id)
        #expect(try await s.liveAction(target: .reminder, source: .task, sourceID: task.id) == nil)
    }

    @Test func regeneratingMinutesNeverDropsATaskThatWasSentToReminders() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Ana prepara la demo", "Recapitulamos el acta anterior"])
        let segs = try await s.segments(of: m)
        try await s.applyMinutes(Self.minutes(segs, tasks: [("Preparar la demo", 0), ("Leer el acta anterior", 1)]), to: m)
        let recap = try #require(try await s.tasks(m).first { $0.text == "Leer el acta anterior" })
        let intent = try await s.beginAction(target: .reminder, source: .task, sourceID: recap.id, containerID: "L", titleHash: "h")
        try await s.completeAction(intent.action.id, itemID: "r1", externalID: "e1")
        // "Regenerate" with an extraction that no longer keeps the recap (the new one): sending the task made it the person's.
        try await s.applyMinutes(Self.minutes(segs, tasks: [("Preparar la demo", 0)]), to: m)
        let kept = try #require(try await s.tasks(m).first { $0.text == "Leer el acta anterior" })
        #expect(kept.id == recap.id && kept.source == "user", "a task sent to Reminders is the person's: a rewrite of the minutes keeps it")
        #expect(try await s.liveAction(target: .reminder, source: .task, sourceID: recap.id)?.id == intent.action.id, "and its ledger row stays live")
        // A task nothing was done with is the model's, and goes.
        try await s.applyMinutes(Self.minutes(segs, tasks: []), to: m)
        #expect(try await s.tasks(m).map(\.text) == ["Leer el acta anterior"])
    }

    @Test func deletingAMeetingRemovesItsLedgerAndCountsWhatStays() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Ana prepara la demo"])
        let segs = try await s.segments(of: m)
        try await s.applyMinutes(Self.minutes(segs, tasks: [("Preparar la demo", 0)]), to: m)
        let task = try #require(try await s.tasks(m).first)
        let intent = try await s.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: "L", titleHash: "h")
        try await s.completeAction(intent.action.id, itemID: "r1", externalID: nil)
        let follow = try await s.addFollowUp(m, title: "Follow-up", day: DueDay("2026-10-21"))
        let event = try await s.beginAction(target: .event, source: .followUp, sourceID: follow, containerID: "C", titleHash: "e")
        try await s.completeAction(event.action.id, itemID: "ev1", externalID: nil)
        // A reminder the person already had and linked is not one Vauta created: it is not counted.
        let other = try await s.addTask(m, text: "Revisar el contrato")
        _ = try await s.recordLinked(target: .reminder, source: .task, sourceID: other, containerID: "L", itemID: "r2", externalID: nil, titleHash: "h2")
        let counts = try await s.createdActionCounts(ofMeeting: m)
        #expect(counts.reminders == 1 && counts.events == 1)
        try await s.deleteMeeting(m)
        #expect(try await s.intsForTest("SELECT count(*) FROM created_actions") == [0])
        #expect(try await s.intsForTest("SELECT count(*) FROM follow_ups") == [0])
    }

    @Test func actingMakesTheTaskTheUsersAndARewriteKeepsItWithoutATwin() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Ana prepara la demo", "Luis revisa el contrato"])
        let segs = try await s.segments(of: m)
        let proposals = Self.minutes(segs, tasks: [("Preparar la demo", 0), ("Revisar el contrato", 1)])
        try await s.applyMinutes(proposals, to: m)
        let demo = try #require(try await s.tasks(m).first { $0.text == "Preparar la demo" })
        #expect(demo.source == "llm")
        let writer = FakeActionWriter()
        let service = ActionService(store: s, writer: writer)
        let draft = ReminderDraft.make(task: demo, selfEntityID: nil, containerID: "list-work", meetingTitle: "Plan", meetingDate: .now)
        guard case .added(let row) = await service.addReminder(task: demo, draft: draft) else { Issue.record("not added"); return }
        #expect(try await s.tasks(m).first { $0.id == demo.id }?.source == "user")

        // Rewrite with the same minutes, then with different wording: the acted task stays, no twin appears, the ledger row is untouched.
        try await s.applyMinutes(proposals, to: m)
        var reworded = proposals
        reworded.tasks[0] = .init(text: "Prepare the demo for the client", owner: nil, due: nil, segment: segs[0].id, t: segs[0].start)
        try await s.applyMinutes(reworded, to: m)
        let tasks = try await s.tasks(m)
        #expect(tasks.filter { $0.segmentID == segs[0].id }.map(\.id) == [demo.id], "no twin of the task that has a reminder")
        #expect(try await s.action(row.id)?.state == .created)
        #expect(writer.writes == 1)
        // The other task was not acted on, so a rewrite replaces it.
        #expect(tasks.first { $0.segmentID == segs[1].id }?.id != nil)
    }

    @Test func aFailedWriteLeavesTheTaskTheModelsAgain() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Ana prepara la demo"])
        let segs = try await s.segments(of: m)
        try await s.applyMinutes(Self.minutes(segs, tasks: [("Preparar la demo", 0)]), to: m)
        let task = try #require(try await s.tasks(m).first)
        let intent = try await s.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: "L", titleHash: "h")
        #expect(try await s.tasks(m).first?.source == "user")
        try await s.abortAction(intent)
        #expect(try await s.tasks(m).first?.source == "llm")
        #expect(try await s.liveAction(target: .reminder, source: .task, sourceID: task.id) == nil)
    }

    // MARK: Follow-ups

    @Test func detectedFollowUpsAreReplacedButDismissedOnesStay() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Let's meet again on October 21 at 10:00"])
        let seg = try #require(try await s.segments(of: m).first)
        let candidate = FollowUpCandidate(segmentID: seg.id, t: 0, title: "Follow-up", day: DueDay("2026-10-21"), dayInferred: false, minuteOfDay: 600, durationMinutes: 30, quote: "q")
        try await s.storeDetectedFollowUps([candidate], meetingID: m)
        var rows = try await s.followUps(m)
        #expect(rows.count == 1 && rows[0].state == .suggested && rows[0].minuteOfDay == 600)
        try await s.setFollowUpState(rows[0].id, .dismissed)
        try await s.storeDetectedFollowUps([candidate], meetingID: m)
        rows = try await s.followUps(m)
        #expect(rows.count == 1 && rows[0].state == .dismissed, "a dismissed candidate does not come back")
        let manual = try await s.addFollowUp(m, title: "Mine", day: DueDay("2026-11-01"))
        try await s.storeDetectedFollowUps([], meetingID: m)
        #expect(try await s.followUps(m).map(\.id).contains(manual), "the person's own rows are never touched")
    }

    @Test func aFollowUpDeletedLeavesItsEventRowOrphaned() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["x"])
        let follow = try await s.addFollowUp(m, title: "Follow-up", day: DueDay("2026-10-21"))
        let intent = try await s.beginAction(target: .event, source: .followUp, sourceID: follow, containerID: "C", titleHash: "e")
        try await s.completeAction(intent.action.id, itemID: "ev1", externalID: nil)
        try await s.deleteFollowUp(follow)
        #expect(try await s.action(intent.action.id)?.state == .orphaned)
    }
}
