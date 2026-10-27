// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Never twice, undo, permissions and read-back, against the fake writer: no EventKit, no real Reminders.
@Suite("Actions: the service")
struct ActionsServiceTests {
    struct Setup {
        let f: KnowledgeFixture
        let writer: FakeActionWriter
        let meeting: Int64
        var store: MeetingStore { f.store }
        var service: ActionService { ActionService(store: f.store, writer: writer) }

        static func make(_ texts: [String] = ["Send the revised budget to finance"], dues: [String?] = []) async throws -> Setup {
            let f = try KnowledgeFixture()
            let m = try await f.meeting(texts.map { "We agreed: \($0)" })
            let segs = try await f.store.segments(of: m)
            var minutes = ValidatedMinutes()
            minutes.title = "Weekly sync"
            minutes.tasks = texts.enumerated().map { i, text in
                let day = i < dues.count ? dues[i].flatMap { DueDay($0) } : nil
                return .init(text: text, owner: nil, due: day?.startOfDay(in: .current), segment: segs[i].id, t: segs[i].start, dueDay: day)
            }
            try await f.store.applyMinutes(minutes, to: m)
            return Setup(f: f, writer: FakeActionWriter(), meeting: m)
        }

        func tasks() async throws -> [TaskItem] { try await store.tasks(meeting) }
        func draft(_ task: TaskItem, list: String = "list-work", alert: Int? = nil) -> ReminderDraft {
            ReminderDraft.make(task: task, selfEntityID: nil, containerID: list, alertMinuteOfDay: alert, meetingTitle: "Weekly sync",
                             meetingDate: DueDay(year: 2026, month: 10, day: 5)!.startOfDay(in: .current).addingTimeInterval(36_000))
        }
    }

    // MARK: Never twice

    @Test func aDoublePressWritesOnce() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let service = t.service
        async let a = service.addReminder(task: task, draft: t.draft(task))
        async let b = service.addReminder(task: task, draft: t.draft(task))
        let results = await [a, b]
        #expect(results.filter { if case .added = $0 { true } else { false } }.count == 1)
        #expect(results.contains { if case .duplicate(.alreadyAdded) = $0 { true } else { false } })
        #expect(t.writer.writes == 1)
    }

    @Test func reopeningTheMeetingOrRelaunchingNeverAddsASecondOne() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        guard case .added = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        // A fresh service on the same store (the meeting window closed and opened), then a relaunch (the store reopened from disk).
        guard case .duplicate(.alreadyAdded(let row)) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("added twice"); return }
        #expect(row.state == .created)
        try await t.f.reopen()
        let again = ActionService(store: t.f.store, writer: t.writer)
        let reopened = try #require(try await t.f.store.tasks(t.meeting).first)
        guard case .duplicate(.alreadyAdded) = await again.addReminder(task: reopened, draft: t.draft(reopened)) else { Issue.record("added after a relaunch"); return }
        #expect(t.writer.writes == 1)
    }

    @Test func anEqualOrNearlyEqualReminderInTheTargetListIsOfferedNotDuplicated() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        t.writer.seedReminder("send the revised budget to finance team", in: "list-work")
        t.writer.seedReminder("Send the revised budget to finance", in: "list-home")   // another list: never read
        guard case .duplicate(.existing(let item)) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("expected the existing reminder"); return }
        #expect(item.containerID == "list-work")
        #expect(t.writer.writes == 0)
        #expect(Set(t.writer.containersRead) == ["list-work"], "only the list being added to is read")
        // Use This One records it without writing, and makes the task the person's.
        let linked = try #require(await t.service.useExisting(task: task, finding: .existing(item)))
        #expect(linked.state == .linked && linked.itemID == item.itemID)
        #expect(try await t.f.store.tasks(t.meeting).first?.source == "user")
        #expect(t.writer.writes == 0)
        guard case .duplicate(.alreadyAdded) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("linked task added"); return }
    }

    @Test func addAnywayWritesWhenThePersonInsistsButNeverOverridesTheLedger() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        t.writer.seedReminder("Send the revised budget to finance", in: "list-work")
        guard case .added = await t.service.addReminder(task: task, draft: t.draft(task), acceptingDuplicate: true) else { Issue.record("not added"); return }
        guard case .duplicate(.alreadyAdded) = await t.service.addReminder(task: task, draft: t.draft(task), acceptingDuplicate: true) else { Issue.record("ledger overridden"); return }
        #expect(t.writer.writes == 1)
    }

    @Test func aSimilarButDifferentTitleIsNotACollision() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        t.writer.seedReminder("Book the supplier visit", in: "list-work")
        t.writer.seedReminder("Send the revised budget to finance", in: "list-work", completed: true)   // completed ones are not read
        guard case .added = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("blocked wrongly"); return }
    }

    @Test func aTaskDeletedHereKeepsItsReminderCountingAgainstDuplicates() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        try await t.store.deleteTask(task.id)
        #expect(try await t.store.action(row.id)?.state == .orphaned)
        // The person adds the same task again in the same meeting.
        let again = try await t.store.addTask(t.meeting, text: "Send the revised budget to finance")
        let task2 = try #require(try await t.tasks().first { $0.id == again })
        guard case .duplicate(.orphan(let orphan)) = await t.service.addReminder(task: task2, draft: t.draft(task2)) else { Issue.record("expected the orphan"); return }
        #expect(orphan.id == row.id && t.writer.writes == 1)
        let claimed = try #require(await t.service.useExisting(task: task2, finding: .orphan(orphan)))
        #expect(claimed.state == .linked && claimed.itemID == row.itemID)
        #expect(try await t.store.action(row.id) == nil, "the orphan's identifiers moved to the new row")
        #expect(t.writer.writes == 1)
    }

    @Test func addAnywayOnAnOrphanWritesASecondReminderOnPurpose() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        _ = await t.service.addReminder(task: task, draft: t.draft(task))
        try await t.store.deleteTask(task.id)
        let again = try await t.store.addTask(t.meeting, text: "Send the revised budget to finance")
        let task2 = try #require(try await t.tasks().first { $0.id == again })
        guard case .added = await t.service.addReminder(task: task2, draft: t.draft(task2), acceptingDuplicate: true) else { Issue.record("not added"); return }
        #expect(t.writer.writes == 2)
    }

    // MARK: Crashes

    @Test func aSaveThatThrewAfterSavingIsAdoptedNotRepeated() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        t.writer.setFailure(.afterSave)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("expected the saved item to be adopted"); return }
        #expect(row.state == .created && row.itemID != nil)
        t.writer.setFailure(.none)
        guard case .duplicate = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("added twice"); return }
        #expect(t.writer.writes == 1)
    }

    /// The process dies after EventKit saved and before the ledger row was promoted: the next Add finds the item by title hash.
    @Test func aCrashAfterTheSaveIsRecoveredByTheNextAddEvenWithAnEditedTitle() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        var draft = t.draft(task)
        draft.title = "Budget to finance by Friday"   // the person edited the title in the editor
        let intent = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash)
        _ = try await t.writer.addReminder(draft.write())   // saved; the process dies here
        #expect(try await t.store.action(intent.action.id)?.state == .writing)
        let afterRestart = ActionService(store: t.store, writer: t.writer)
        guard case .duplicate(.alreadyAdded(let row)) = await afterRestart.addReminder(task: task, draft: draft) else { Issue.record("not recovered"); return }
        #expect(row.state == .created && row.itemID != nil)
        #expect(t.writer.writes == 1)
    }

    @Test func aCrashBeforeTheSaveLeavesNothingAndTheNextAddWorks() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task)
        let intent = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash)
        let afterRestart = ActionService(store: t.store, writer: t.writer)
        guard case .added = await afterRestart.addReminder(task: task, draft: draft) else { Issue.record("blocked by a dead intent"); return }
        #expect(try await t.store.actions(ofMeeting: t.meeting).count == 1 && intent.action.state == .writing, "the dead intent was deleted; only the new row remains")
        #expect(try await t.store.writingActions().isEmpty)
        #expect(t.writer.writes == 1)
    }

    @Test func aCrashRecoveredLaterFindsTheItemInItsOwnListOnly() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task, list: "list-work")
        _ = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: "list-work", titleHash: draft.titleHash)
        // An item with the same title in another list, created after the intent, is not it.
        _ = try await t.writer.addReminder(ReminderWrite(title: draft.write().title, containerID: "list-home", due: nil, alert: false, notes: nil))
        await ActionService(store: t.store, writer: t.writer).reconcileWriting(meetingID: t.meeting)
        #expect(try await t.store.writingActions().isEmpty)
        #expect(try await t.store.liveAction(target: .reminder, source: .task, sourceID: task.id) == nil, "not adopted")
    }

    @Test func aFailedSaveLeavesNothingBehindAndTheNextTryWorks() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        t.writer.setFailure(.beforeSave)
        #expect(await t.service.addReminder(task: task, draft: t.draft(task)) == .failed)
        #expect(try await t.store.writingActions().isEmpty)
        #expect(try await t.f.store.tasks(t.meeting).first?.source == "llm", "the task is not the person's: nothing was added")
        t.writer.setFailure(.none)
        guard case .added = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("retry failed"); return }
        #expect(t.writer.writes == 1)
    }

    // MARK: Identifier changes and missing items

    @Test func aSyncThatReIdentifiesTheItemIsFollowedAndUndoStillWorks() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        let old = try #require(row.itemID)
        t.writer.reidentify(old, as: "synced-1")
        let status = await t.service.readBack(tasks: [task])
        #expect(status[task.id] == .inReminders)
        #expect(try await t.store.action(row.id)?.itemID == "synced-1", "the ledger followed the new identifier")
        #expect(await t.service.remove(actionID: row.id) == .removed)
        #expect(t.writer.removals == 1)
    }

    @Test func anItemDeletedInRemindersShowsAsMissingAndCanBeAddedAgain() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        t.writer.deleteExternally(try #require(row.itemID))
        #expect(await t.service.readBack(tasks: [task])[task.id] == .missing)
        #expect(try await t.store.action(row.id)?.state == .missing)
        #expect(await t.service.readBack(tasks: [task])[task.id] == .missing, "it keeps saying so")
        guard case .added(let second) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("Add Again failed"); return }
        #expect(second.id != row.id && t.writer.writes == 2)
    }

    // MARK: Undo and removal

    @Test func undoRemovesOnlyWhatVautaCreatedAndNeverALinkedItem() async throws {
        let t = try await Setup.make(["Send the revised budget to finance", "Book the supplier visit"])
        let tasks = try await t.tasks()
        let mine = t.writer.seedReminder("My own reminder", in: "list-work")
        guard case .added(let created) = await t.service.addReminder(task: tasks[0], draft: t.draft(tasks[0])) else { Issue.record("not added"); return }
        let existing = t.writer.seedReminder("Book the supplier visit", in: "list-work")
        let item = try #require(await t.writer.item(.reminder, itemID: existing, externalID: nil, containerID: nil))
        let linked = try #require(await t.service.useExisting(task: tasks[1], finding: .existing(item)))
        #expect(await t.service.remove(actionID: linked.id) == .notRemovable, "a linked reminder is never removed")
        #expect(await t.service.remove(actionID: created.id) == .removed)
        #expect(t.writer.log.filter { if case .remove = $0 { true } else { false } } == [.remove(.reminder, try #require(created.itemID))])
        #expect(t.writer.allItems.map(\.itemID).contains(mine) && t.writer.allItems.map(\.itemID).contains(existing))
        #expect(await t.service.remove(actionID: created.id) == .notRemovable, "already removed")
        #expect(try await t.store.tasks(t.meeting).count == 2, "the tasks stay the person's")
    }

    @Test func aReminderEditedInRemindersAsksBeforeItIsRemoved() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        t.writer.editExternally(try #require(row.itemID), title: "Send the budget (edited)")
        #expect(await t.service.remove(actionID: row.id) == .editedElsewhere)
        #expect(t.writer.removals == 0)
        #expect(await t.service.remove(actionID: row.id, confirmedEdited: true) == .removed)
    }

    @Test func undoOfABatchRemovesEachRowAndOnlyThose() async throws {
        let t = try await Setup.make(["Send the revised budget to finance", "Book the supplier visit"])
        let tasks = try await t.tasks()
        var rows: [CreatedAction] = []
        for task in tasks { if case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) { rows.append(row) } }
        let result = await t.service.undo(actionIDs: rows.map(\.id))
        #expect(rows.allSatisfy { result[$0.id] == .removed } && t.writer.removals == 2 && t.writer.allItems.isEmpty)
    }

    @Test func aMeetingOrTaskDeletionNeverRemovesAnythingFromReminders() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        _ = await t.service.addReminder(task: task, draft: t.draft(task))
        try await t.store.deleteTask(task.id)
        try await t.store.deleteMeeting(t.meeting)
        #expect(t.writer.removals == 0 && t.writer.allItems.count == 1)
    }

    // MARK: Permissions

    @Test func accessIsNeverRequestedByTheServiceAndNothingIsWrittenWithoutIt() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task)
        for state in [ActionAccess.notDetermined, .denied, .restricted, .writeOnly] {
            t.writer.setAccess(.reminder, state)
            #expect(await t.service.addReminder(task: task, draft: draft) == .accessNeeded(state))
        }
        #expect(t.writer.writes == 0 && t.writer.accessRequests.isEmpty)
        #expect(try await t.store.writingActions().isEmpty && t.f.store != nil)
        // The person presses Allow Access…; the same draft is then added.
        t.writer.setAccess(.reminder, .notDetermined)
        #expect(await t.writer.requestAccess(.reminder))
        guard case .added = await t.service.addReminder(task: task, draft: draft) else { Issue.record("not added after the grant"); return }
        #expect(t.writer.accessRequests == [.reminder] && t.writer.writes == 1)
    }

    @Test func aListThatIsGoneIsNotWrittenTo() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        #expect(await t.service.addReminder(task: task, draft: t.draft(task, list: "deleted-list")) == .noContainer)
        #expect(t.writer.writes == 0)
    }

    // MARK: Read back

    @Test func aReminderCompletedInRemindersOffersMarkDoneHereAndNothingChangesByItself() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        t.writer.completeExternally(try #require(row.itemID))
        #expect(await t.service.readBack(tasks: [task])[task.id] == .doneInReminders)
        #expect(try await t.store.tasks(t.meeting).first?.status == .open, "Vauta never completes a task by itself")
        let writesBefore = t.writer.log.count
        await t.service.markDoneHere(taskID: task.id)
        #expect(try await t.store.tasks(t.meeting).first?.status == .done)
        #expect(t.writer.log.count == writesBefore, "marking it done here writes nothing to Reminders")
    }

    @Test func aStaleDueDateIsShownAndNeverWritten() async throws {
        let t = try await Setup.make(dues: ["2026-10-24"])
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        t.writer.setDueExternally(try #require(row.itemID), DueDay("2026-10-10"))
        #expect(await t.service.readBack(tasks: [task])[task.id] == .dueDiffers(reminder: DueDay("2026-10-10"), task: DueDay("2026-10-24")))
        #expect(t.writer.writes == 1)
    }

    @Test func readBackNeedsFullAccessAndReadsNothingWithoutIt() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        _ = await t.service.addReminder(task: task, draft: t.draft(task))
        t.writer.setAccess(.reminder, .denied)
        #expect(await t.service.readBack(tasks: [task]).isEmpty)
    }

    // MARK: What is written

    @Test func theReminderCarriesExactlyTheDraftsFieldsAndNoTranscriptText() async throws {
        let t = try await Setup.make(dues: ["2026-10-16"])
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task, alert: 540)) else { Issue.record("not added"); return }
        let itemID = try #require(row.itemID)
        let written = try #require(t.writer.storedReminder(itemID))
        #expect(written.title == "Send the revised budget to finance" && written.containerID == "list-work")
        #expect(written.due?.year == 2026 && written.due?.month == 10 && written.due?.day == 16 && written.due?.hour == 9 && written.alert)
        #expect(written.notes?.contains("We agreed") == false, "no transcript text")
        #expect(t.writer.log == [.addReminder(written)])
    }

    // MARK: Events

    @Test func aFollowUpEventIsAddedOnceAndALookAlikeInTheCalendarIsNotDuplicated() async throws {
        let t = try await Setup.make()
        let follow = try await t.store.addFollowUp(t.meeting, title: "Follow-up: Weekly sync", day: DueDay("2026-10-21"), minuteOfDay: 600)
        let fu = try #require(try await t.store.followUps(t.meeting).first { $0.id == follow })
        let draft = EventDraft(title: "Follow-up: Weekly sync", containerID: "cal-work", day: DueDay("2026-10-21")!, minuteOfDay: 600, durationMinutes: 30, timeZone: .current)
        t.writer.seedEvent("Weekly sync follow-up", on: DueDay("2026-10-21")!)
        guard case .duplicate(.existingEvent) = await t.service.addEvent(followUp: fu, draft: draft) else { Issue.record("expected the existing event"); return }
        #expect(t.writer.writes == 0)
        let other = EventDraft(title: "Budget workshop", containerID: "cal-work", day: DueDay("2026-10-21")!, minuteOfDay: 840, durationMinutes: 60, timeZone: .current)
        guard case .added(let row) = await t.service.addEvent(followUp: fu, draft: other) else { Issue.record("not added"); return }
        guard case .duplicate(.alreadyAdded) = await t.service.addEvent(followUp: fu, draft: other) else { Issue.record("added twice"); return }
        #expect(t.writer.writes == 1)
        #expect(await t.service.remove(actionID: row.id) == .removed)
    }

    @Test func withoutFullCalendarAccessNoPromptIsRaisedAndAnICSIsHandedOver() async throws {
        let t = try await Setup.make()
        t.writer.setAccess(.event, .notDetermined)
        let follow = try await t.store.addFollowUp(t.meeting, title: "Follow-up", day: DueDay("2026-10-21"), minuteOfDay: 600)
        let fu = try #require(try await t.store.followUps(t.meeting).first { $0.id == follow })
        let draft = EventDraft(title: "Follow-up", containerID: "cal-work", day: DueDay("2026-10-21")!, minuteOfDay: 600, durationMinutes: 30, timeZone: TimeZone(identifier: "UTC")!)
        #expect(await t.service.addEvent(followUp: fu, draft: draft) == .handOff)
        #expect(t.writer.accessRequests.isEmpty && t.writer.writes == 0)
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: caches) }
        let first = await t.service.handOffEvent(followUp: fu, draft: draft, meetingTitle: "Weekly sync", meetingDate: .now, caches: caches)
        guard case .added(let row) = first.outcome, let file = first.file else { Issue.record("no hand-off"); return }
        #expect(row.state == .handedOff && row.itemID == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let second = await t.service.handOffEvent(followUp: fu, draft: draft, meetingTitle: "Weekly sync", meetingDate: .now, caches: caches)
        guard case .duplicate(.alreadyAdded) = second.outcome else { Issue.record("handed off twice"); return }
        #expect(await t.service.remove(actionID: row.id) == .notRemovable, "Calendar owns it now; Vauta can only forget the row")
        await t.service.forget(actionID: row.id)
        #expect(try await t.store.liveAction(target: .ics, source: .followUp, sourceID: follow) == nil)
    }
}
