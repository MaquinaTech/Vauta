// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A write that was interrupted (a dead `writing` row) is settled when a surface opens, never adopts something the person typed
/// later, works for events too, and a temporary lookup failure never loses a reminder. Fake writer only.
@Suite("Actions: recovery of interrupted writes")
struct ActionsRecoveryTests {
    typealias Setup = ActionsServiceTests.Setup

    // MARK: Settled when the editor checks

    @Test func aDeadIntentWithNothingSavedDoesNotBlockTheEditorCheck() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task)
        _ = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash)
        let restarted = ActionService(store: t.store, writer: t.writer)
        #expect(await restarted.check(task: task, draft: draft) == .none, "the editor can Add: nothing is 'already in Reminders'")
        #expect(try await t.store.writingActions().isEmpty)
        guard case .added = await restarted.addReminder(task: task, draft: draft) else { Issue.record("Add stayed disabled"); return }
        #expect(t.writer.writes == 1)
    }

    @Test func aDeadIntentWhoseItemWasSavedShowsAsInRemindersInTheEditorCheck() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task)
        _ = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash)
        _ = try await t.writer.addReminder(draft.write())
        let restarted = ActionService(store: t.store, writer: t.writer)
        guard case .alreadyAdded(let row) = await restarted.check(task: task, draft: draft) else { Issue.record("not recovered"); return }
        #expect(row.state == .created && row.itemID != nil, "a real row with an item to open, not a `writing` one")
        let status = await restarted.readBack(tasks: [task])
        #expect(status[task.id] == .inReminders)
    }

    @Test func withoutFullAccessADeadIntentIsLeftAloneNotDeleted() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task)
        _ = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash)
        _ = try await t.writer.addReminder(draft.write())
        t.writer.setAccess(.reminder, .denied)
        await ActionService(store: t.store, writer: t.writer).reconcileWriting()
        #expect(try await t.store.writingActions().count == 1, "nothing is concluded from not being able to look")
        t.writer.setAccess(.reminder, .full)
        await ActionService(store: t.store, writer: t.writer).reconcileWriting()
        #expect(try await t.store.writingActions().isEmpty)
        #expect(try await t.store.liveAction(target: .reminder, source: .task, sourceID: task.id)?.state == .created)
    }

    // MARK: Never adopt what the person typed

    @Test func aSameTitleReminderTypedMinutesLaterIsNotAdopted() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task)
        _ = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash)
        // The save never happened. Ten minutes later the person types the same reminder in the same list.
        t.writer.setClock { Date().addingTimeInterval(600) }
        let typed = try await t.writer.addReminder(draft.write())
        t.writer.setClock { Date() }
        await ActionService(store: t.store, writer: t.writer).reconcileWriting(meetingID: t.meeting)
        #expect(try await t.store.writingActions().isEmpty)
        #expect(try await t.store.liveAction(target: .reminder, source: .task, sourceID: task.id) == nil, "not Vauta's: it never undoes or removes it")
        #expect(t.writer.allItems.map(\.itemID).contains(typed.itemID))
    }

    @Test func aSavedReminderThatWasCompletedBeforeRecoveryIsStillAdoptedNotWrittenAgain() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task)
        _ = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash)
        let saved = try await t.writer.addReminder(draft.write())
        // The crash came after the save; the person ticked the reminder off in Reminders before Vauta looked again.
        t.writer.completeExternally(saved.itemID)
        let restarted = ActionService(store: t.store, writer: t.writer)
        await restarted.reconcileWriting(meetingID: t.meeting)
        #expect(try await t.store.writingActions().isEmpty)
        let row = try #require(try await t.store.liveAction(target: .reminder, source: .task, sourceID: task.id))
        #expect(row.state == .created && row.itemID == saved.itemID, "adopted, so a new Add finds it and does not write a second reminder")
        guard case .duplicate(.alreadyAdded) = await restarted.addReminder(task: task, draft: draft) else { Issue.record("a second reminder was offered"); return }
        #expect(t.writer.writes == 1)
    }

    @Test func theFakeBoundsCompletedRemindersByCompletionDate() async throws {
        let writer = FakeActionWriter()
        let old = writer.seedReminder("Old", completed: true, completedAt: Date().addingTimeInterval(-3_600))
        let recent = writer.seedReminder("Recent", completed: true, completedAt: Date().addingTimeInterval(60))
        let found = await writer.completedReminders(in: "list-work", since: Date()).map(\.itemID)
        #expect(found == [recent] && !found.contains(old), "only completions at or after the bound are read")
    }

    @Test func aSaveThatReturnedLateIsStillAdopted() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let draft = t.draft(task)
        _ = try await t.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash)
        t.writer.setClock { Date().addingTimeInterval(30) }
        _ = try await t.writer.addReminder(draft.write())
        await ActionService(store: t.store, writer: t.writer).reconcileWriting(meetingID: t.meeting)
        #expect(try await t.store.liveAction(target: .reminder, source: .task, sourceID: task.id)?.state == .created)
    }

    // MARK: Events

    private func followUp(_ t: Setup) async throws -> (FollowUp, EventDraft) {
        let id = try await t.store.addFollowUp(t.meeting, title: "Follow-up: Weekly sync", day: DueDay("2026-10-21"), minuteOfDay: 600)
        let fu = try #require(try await t.store.followUps(t.meeting).first { $0.id == id })
        return (fu, EventDraft(title: "Follow-up: Weekly sync", containerID: "cal-work", day: DueDay("2026-10-21")!, minuteOfDay: 600, durationMinutes: 30, timeZone: .current))
    }

    @Test func aCrashAfterAnEventWasSavedIsRecoveredNotRepeated() async throws {
        let t = try await Setup.make()
        let (fu, draft) = try await followUp(t)
        let intent = try await t.store.beginAction(target: .event, source: .followUp, sourceID: fu.id, containerID: draft.containerID, titleHash: draft.titleHash)
        _ = try await t.writer.addEvent(draft.write())   // saved; the process dies here
        #expect(try await t.store.action(intent.action.id)?.state == .writing)
        let restarted = ActionService(store: t.store, writer: t.writer)
        guard case .duplicate(.alreadyAdded(let row)) = await restarted.addEvent(followUp: fu, draft: draft) else { Issue.record("not recovered"); return }
        #expect(row.state == .created && row.itemID != nil && row.target == .event)
        #expect(t.writer.writes == 1)
        #expect(try await t.store.followUps(t.meeting).first?.state == .done, "the follow-up is done in the same commit as its event")
    }

    @Test func aCrashAfterAnEventWasSavedWithAnEditedTitleIsRecoveredToo() async throws {
        let t = try await Setup.make()
        let (fu, draft) = try await followUp(t)
        let intent = try await t.store.beginAction(target: .event, source: .followUp, sourceID: fu.id, containerID: draft.containerID, titleHash: draft.titleHash)
        _ = try await t.writer.addEvent(draft.write())
        let restarted = ActionService(store: t.store, writer: t.writer)
        // The editor check of a new session settles the row before anything else.
        guard case .alreadyAdded = await restarted.checkEvent(followUp: fu, draft: draft) else { Issue.record("not recovered by the check"); return }
        #expect(try await t.store.action(intent.action.id)?.state == .created)
    }

    @Test func aDeadEventIntentWithNothingSavedIsDeleted() async throws {
        let t = try await Setup.make()
        let (fu, draft) = try await followUp(t)
        _ = try await t.store.beginAction(target: .event, source: .followUp, sourceID: fu.id, containerID: draft.containerID, titleHash: draft.titleHash)
        let restarted = ActionService(store: t.store, writer: t.writer)
        guard case .added = await restarted.addEvent(followUp: fu, draft: draft) else { Issue.record("blocked by a dead intent"); return }
        #expect(t.writer.writes == 1)
        #expect(try await t.store.writingActions().isEmpty)
    }

    // MARK: Ledger bookkeeping

    @Test func aRedetectionKeepsAFollowUpThatHasALiveEventRow() async throws {
        let t = try await Setup.make()
        let id = try await t.store.addFollowUp(t.meeting, title: "Follow-up", day: DueDay("2026-10-21"), source: .detected)
        _ = try await t.store.beginAction(target: .event, source: .followUp, sourceID: id, containerID: "cal-work", titleHash: ActionTitle.hash("Follow-up"))
        try await t.store.storeDetectedFollowUps([], meetingID: t.meeting)
        #expect(try await t.store.followUps(t.meeting).map(\.id) == [id], "the suggestion with a live row is not deleted")
        #expect(try await t.store.liveAction(target: .event, source: .followUp, sourceID: id) != nil)
    }

    @Test func aTitleThatIsEmptyIsNeverWritten() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        var draft = t.draft(task)
        draft.title = "  \n "
        #expect(await t.service.addReminder(task: task, draft: draft) == .failed)
        #expect(t.writer.writes == 0)
        #expect(try await t.store.writingActions().isEmpty)
    }

    // MARK: A reminder that cannot be found for a moment

    @Test func aReminderMovedToAnotherListIsStillFoundByItsExternalIdentifier() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        let old = try #require(row.itemID)
        t.writer.reidentify(old, as: "synced-9")
        t.writer.moveExternally("synced-9", to: "list-home")
        #expect(await t.service.readBack(tasks: [task])[task.id] == .inReminders, "moved and re-identified, not lost")
        let after = try await t.store.action(row.id)
        #expect(after?.state == .created && after?.itemID == "synced-9")
    }

    @Test func aMissingRowComesBackWhenTheReminderIsFoundAgain() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        guard case .added(let row) = await t.service.addReminder(task: task, draft: t.draft(task)) else { Issue.record("not added"); return }
        try await t.store.setActionState(row.id, .missing)   // a lookup failed during a sync
        #expect(await t.service.readBack(tasks: [task])[task.id] == .inReminders)
        #expect(try await t.store.action(row.id)?.state == .created)
    }

    @Test func aMissingRowOfALinkedReminderComesBackAsLinkedNeverAsOneVautaMade() async throws {
        let t = try await Setup.make()
        let task = try #require(try await t.tasks().first)
        let existing = t.writer.seedReminder(t.draft(task).title, in: "list-work")
        let item = try #require(await t.writer.item(.reminder, itemID: existing, externalID: nil, containerID: nil))
        let linked = try #require(await t.service.useExisting(task: task, finding: .existing(item)))
        try await t.store.setActionState(linked.id, .missing)
        _ = await t.service.readBack(tasks: [task])
        #expect(try await t.store.action(linked.id)?.state == .linked)
        #expect(await t.service.remove(actionID: linked.id) == .notRemovable)
    }
}
