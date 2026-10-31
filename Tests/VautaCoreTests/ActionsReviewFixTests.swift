// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Fixes from the review of the post-meeting actions: due days that do not drift with the time zone, a ledger row that is
/// orphaned while it is written, an `.ics` hand-off left by a crash, what the batch writes, and a due day the person chose.
@Suite("Actions: review fixes")
struct ActionsReviewFixTests {
    typealias Setup = ActionsServiceTests.Setup
    static let madrid = TimeZone(identifier: "Europe/Madrid")!
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    // MARK: Due days across time zones

    @Test func aDueDaySetInMadridIsTheSameDayInLosAngeles() {
        let day = DueDay(year: 2026, month: 10, day: 16)!
        let task = TaskItem(id: 1, meetingID: 1, segmentID: nil, t: nil, text: "Send", ownerID: nil, ownerName: nil,
                            due: day.startOfDay(in: Self.madrid), status: .open, source: "user", createdAt: .now, meetingTitle: nil, dueDay: day)
        #expect(DueDay.containing(task.due!, in: Self.losAngeles) == DueDay(year: 2026, month: 10, day: 15)!, "the instant is the 15th there")
        #expect(task.displayDay(in: Self.losAngeles) == day, "the table shows the day the task says")
        let old = TaskItem(id: 2, meetingID: 1, segmentID: nil, t: nil, text: "Old", ownerID: nil, ownerName: nil,
                           due: day.startOfDay(in: Self.madrid), status: .open, source: "user", createdAt: .now, meetingTitle: nil)
        #expect(old.displayDay(in: Self.madrid) == day, "a task stored before the day existed falls back to its due date")
    }

    @Test func theDraftShowsTheDueDayAndIsNotDirtyUntilTheDayChanges() {
        let day = DueDay(year: 2026, month: 10, day: 16)!
        let task = TaskItem(id: 1, meetingID: 1, segmentID: nil, t: nil, text: "Send", ownerID: nil, ownerName: nil,
                            due: day.startOfDay(in: Self.madrid), status: .open, source: "user", createdAt: .now, meetingTitle: nil, dueDay: day)
        var draft = TaskDraft(task, zone: Self.losAngeles)
        #expect(DueDay.containing(draft.due, in: Self.losAngeles) == day, "the picker opens on the 16th")
        #expect(!draft.isDirty && draft.edited.due == task.due, "an untouched day keeps its stored moment")
        draft.due = DueDay(year: 2026, month: 10, day: 20)!.startOfDay(in: Self.losAngeles)
        #expect(draft.isDirty && draft.edited.due == draft.due)
        draft.hasDue = false
        #expect(draft.isDirty && draft.edited.due == nil)
    }

    // MARK: The ledger while writing

    @Test func aRowOrphanedWhileItsItemWasBeingSavedStaysAnOrphanWithItsIdentifiers() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task)
        let intent = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash)
        try await t.store.deleteTask(task.id)
        try await t.store.completeAction(intent.action.id, itemID: "r1", externalID: "e1")
        let row = try #require(try await t.store.action(intent.action.id))
        #expect(row.state == .orphaned && row.itemID == "r1", "never a live row for a task that is gone")
        #expect(try await t.store.liveReminderIdentifiers().itemIDs.isEmpty)
        #expect(try await t.store.orphanedAction(meetingID: row.meetingID, target: .reminder, titleHash: draft.titleHash) != nil, "still counts against a duplicate")
    }

    @Test func aDeadIcsHandOffIsTakenBackWithoutCalendarAccess() async throws {
        let t = try await Setup.make()
        let id = try await t.store.addFollowUp(t.meeting, title: "Follow-up: Weekly sync", day: DueDay(year: 2026, month: 10, day: 21)!, minuteOfDay: 600, durationMinutes: 30)
        let intent = try await t.store.beginAction(target: .ics, source: .followUp, sourceID: id, containerID: nil, titleHash: "h")
        t.writer.setAccess(.event, .notDetermined)
        t.writer.setAccess(.reminder, .notDetermined)
        // Dated ahead, so it is within the 10 s grace however long a busy machine takes to reach the next line.
        try await t.store.executeForTest("UPDATE created_actions SET written_at = ? WHERE id = ?",
                                         [.real(AppClock.now.timeIntervalSince1970 + 3_600), .integer(intent.action.id)])
        await t.service.reconcileWriting()
        #expect(try await t.store.writingActions().count == 1, "a hand-off in progress is left alone")
        try await t.store.executeForTest("UPDATE created_actions SET written_at = ? WHERE id = ?",
                                         [.real(AppClock.now.timeIntervalSince1970 - 120), .integer(intent.action.id)])
        await t.service.reconcileWriting()
        let remaining = try await t.store.writingActions()
        let live = try await t.store.liveAction(target: .ics, source: .followUp, sourceID: id)
        #expect(remaining.isEmpty && live == nil)
    }

    // MARK: What the batch writes

    @Test func aDueDayBeforeTheMeetingOrAYearAfterIsLeftOutAndSaysSo() async throws {
        let t = try await Setup.make(["Plausible", "Years ago", "Far away"], dues: ["2026-10-16", "2005-01-03", "2028-01-03"])
        let tasks = try await t.tasks()
        let meeting = DueDay(year: 2026, month: 10, day: 5)!.startOfDay(in: .current).addingTimeInterval(36_000)
        let plans = tasks.map { ReminderDraft.dueDay(of: $0, meetingDate: meeting, meetingTimeZone: .current) }
        #expect(plans[0].use == DueDay(year: 2026, month: 10, day: 16)! && plans[0].skipped == nil)
        #expect(plans[1].use == nil && plans[1].skipped == DueDay(year: 2005, month: 1, day: 3)!)
        #expect(plans[2].use == nil && plans[2].skipped != nil)
        for (task, plan) in zip(tasks, plans) {
            let draft = ReminderDraft.make(task: task, selfEntityID: nil, containerID: "list-work", meetingTitle: "Weekly sync", meetingDate: meeting)
            #expect(draft.dueDay == plan.use && draft.skippedDueDay == plan.skipped, "the row and the write agree")
        }
    }

    // MARK: A due day the person chose

    @Test func aDayChosenInTheEditorIsNotAMismatchUntilSomethingChanges() async throws {
        let t = try await Setup.make(dues: ["2026-10-16"])
        let task = try #require(try await t.tasks().first)
        var draft = t.draft(task)
        draft.dueDay = DueDay(year: 2026, month: 10, day: 20)
        guard case .added = await t.service.addReminder(task: task, draft: draft) else { Issue.record("not added"); return }
        #expect(await t.service.readBack(tasks: [task])[task.id] == .inReminders, "Vauta wrote exactly what the person chose")
        // The task's day changes later (a carried-over task): now it is a mismatch.
        var edited = task
        edited.due = DueDay(year: 2026, month: 10, day: 22)!.startOfDay(in: .current)
        try await t.store.updateTask(edited)
        let moved = try #require(try await t.tasks().first)
        #expect(moved.dueDay == DueDay(year: 2026, month: 10, day: 22)!)
        #expect(await t.service.readBack(tasks: [moved])[moved.id] == .dueDiffers(reminder: DueDay(year: 2026, month: 10, day: 20)!, task: DueDay(year: 2026, month: 10, day: 22)!))
    }

    @Test func aReminderChangedInRemindersAfterTheWriteIsAMismatch() async throws {
        let t = try await Setup.make(dues: ["2026-10-16"])
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        #expect(await t.service.readBack(tasks: [task])[task.id] == .inReminders)
        t.writer.setDueExternally(try #require(row.itemID), DueDay(year: 2026, month: 10, day: 30))
        #expect(await t.service.readBack(tasks: [task])[task.id] == .dueDiffers(reminder: DueDay(year: 2026, month: 10, day: 30)!, task: DueDay(year: 2026, month: 10, day: 16)!))
    }
}
