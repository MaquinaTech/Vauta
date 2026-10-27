// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private func oct(_ day: Int) -> DueDay { DueDay(year: 2026, month: 10, day: day)! }

private final class TestKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// The editors, the Follow-up sheet and the undo bar, on a temporary store and a `FakeActionWriter`: nothing here reaches Reminders,
/// Calendar or Mail, and no test asks macOS for anything.
@Suite("Actions: editors and sheet")
@MainActor
struct ActionsModelTests {
    struct Rig {
        let directory: URL
        let store: MeetingStore
        let history: MeetingsModel
        let actions: ActionsModel
        let fake: FakeActionWriter
        let meeting: Int64
        let tasks: [TaskItem]
    }

    private func rig(reminders: ActionAccess = .full, events: ActionAccess = .full) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-actions-\(UUID().uuidString)", isDirectory: true)
        let store = try MeetingStore(directory: directory, keyStore: TestKey())
        let start = Date(timeIntervalSince1970: 1_791_450_000)
        let meeting = try await store.startMeeting(at: start)
        try await store.setTitle("Weekly sync", of: meeting)
        let segment = try await store.append(Segment(channel: .others, start: 40, end: 50, text: "Let's meet again next Tuesday", isFinal: true), to: meeting)
        let me = try await store.selfEntity()
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana Lopez", email: "ana@example.org"))
        _ = try await store.addTask(meeting, text: "Send the revised budget", ownerID: ana, due: oct(16).startOfDay(in: .current), dueDay: oct(16), segmentID: segment, t: 40)
        _ = try await store.addTask(meeting, text: "Share the slides", ownerID: me, segmentID: segment, t: 41)
        _ = try await store.addTask(meeting, text: "Book the supplier visit", segmentID: segment, t: 42)
        try await store.endMeeting(meeting, at: start.addingTimeInterval(1800))
        let history = MeetingsModel(store: store)
        let fake = FakeActionWriter()
        fake.setAccess(.reminder, reminders)
        fake.setAccess(.event, events)
        history.actions.use(writer: fake)
        history.actions.bringToFront = {}
        history.actions.preferences = ActionsPreferences(defaults: UserDefaults(suiteName: "vauta-actions-test-\(UUID().uuidString)") ?? .standard)
        history.actions.caches = directory.appendingPathComponent("caches", isDirectory: true)
        history.actions.openFile = { _ in }
        let tasks = try await store.tasks(meeting)
        return Rig(directory: directory, store: store, history: history, actions: history.actions, fake: fake, meeting: meeting, tasks: tasks)
    }

    // MARK: Reminder editor

    @Test func nothingIsWrittenUntilAddAndTheDraftIsExactlyWhatIsWritten() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[0])
        let state = try #require(r.actions.reminderEditor)
        #expect(r.fake.writes == 0 && r.actions.page == .reminder)
        #expect(state.draft.title == "Ana Lopez: Send the revised budget", "someone else's task carries the owner")
        #expect(state.draft.dueDay == oct(16) && state.draft.alertMinuteOfDay == nil)
        #expect(state.containers.count == 2 && state.hasList)
        await r.actions.addReminder()
        #expect(r.fake.writes == 1)
        let written = try #require(r.fake.log.first)
        guard case .addReminder(let write) = written else { Issue.record("not a reminder"); return }
        #expect(write.title == "Ana Lopez: Send the revised budget" && write.due == oct(16).floatingComponents && !write.alert)
        #expect(r.actions.page == nil && r.actions.reminderEditor == nil, "the sheet closed")
        #expect(r.actions.undoBar?.kind == .reminder && r.actions.undoBar?.actionIDs.count == 1)
    }

    @Test func aSecondPressNeverWritesASecondReminder() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[1])
        async let first: Void = r.actions.addReminder()
        async let second: Void = r.actions.addReminder()
        _ = await (first, second)
        #expect(r.fake.writes == 1)
        // Opening it again for the same task finds it in the ledger and offers nothing to add.
        await r.actions.openReminderEditor(r.tasks[1])
        #expect(r.actions.reminderEditor?.finding != nil)
        if case .alreadyAdded = r.actions.reminderEditor?.finding {} else { Issue.record("expected alreadyAdded") }
        #expect(r.actions.reminderEditor?.canAdd == false)
    }

    @Test func theDraftSurvivesThePermissionPromptAndTheAskHappensOnlyFromTheButton() async throws {
        let r = try await rig(reminders: .notDetermined)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[0])
        #expect(r.fake.accessRequests.isEmpty, "opening the editor asks for nothing")
        #expect(r.actions.reminderEditor?.access == .notDetermined && r.actions.reminderEditor?.containers.isEmpty == true && r.actions.reminderEditor?.canAdd == false)
        r.actions.reminderEditor?.draft.title = "Ana: send it by Friday"
        r.actions.reminderEditor?.includeMeetingName = false
        // A simulated dismissal of the sheet does not drop the draft, and opening it again reuses it.
        r.actions.dismissedExternally()
        #expect(r.actions.page == nil && r.actions.reminderEditor != nil)
        await r.actions.openReminderEditor(r.tasks[0])
        #expect(r.actions.page == .reminder && r.actions.reminderEditor?.draft.title == "Ana: send it by Friday")
        await r.actions.allowReminderAccess()
        #expect(r.fake.accessRequests == [.reminder])
        let state = try #require(r.actions.reminderEditor)
        #expect(state.access == .full && state.containers.count == 2 && state.hasList && state.canAdd)
        #expect(state.draft.title == "Ana: send it by Friday" && !state.includeMeetingName, "what was typed is still there after the grant")
        #expect(r.fake.writes == 0)
    }

    @Test func aDeniedAccessWritesNothingAndAddIsOff() async throws {
        let r = try await rig(reminders: .denied)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[0])
        #expect(r.actions.reminderEditor?.access == .denied && r.actions.reminderEditor?.canAdd == false)
        await r.actions.addReminder()
        #expect(r.fake.writes == 0 && r.fake.accessRequests.isEmpty)
    }

    @Test func anEqualReminderInTheListIsOfferedAndNothingIsWrittenUntilTheChoice() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        r.fake.seedReminder("Share the slides")
        await r.actions.openReminderEditor(r.tasks[1])
        guard case .existing(let item) = r.actions.reminderEditor?.finding else { Issue.record("expected existing"); return }
        #expect(item.title == "Share the slides" && r.fake.writes == 0)
        #expect(r.fake.containersRead == ["list-work"], "only the list being added to is read")
        await r.actions.addReminder()
        #expect(r.fake.writes == 0, "Add does nothing while a duplicate is waiting for the person")
        await r.actions.useExistingReminder()
        #expect(r.fake.writes == 0)
        #expect(r.actions.state(of: r.tasks[1]).kind == .linked && r.actions.state(of: r.tasks[1]).canUnlink)
    }

    @Test func addAnywayWritesOnceMore() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        r.fake.seedReminder("Share the slides")
        await r.actions.openReminderEditor(r.tasks[1])
        await r.actions.addReminder(acceptingDuplicate: true)
        #expect(r.fake.writes == 1)
    }

    @Test func aFailedSaveSaysSoAndLeavesTheDraft() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        r.fake.setFailure(.beforeSave)
        await r.actions.openReminderEditor(r.tasks[1])
        await r.actions.addReminder()
        #expect(r.actions.reminderEditor?.failed == true && r.actions.page == .reminder && r.fake.writes == 0)
        let row = try await r.store.latestAction(target: .reminder, source: .task, sourceID: r.tasks[1].id)
        #expect(row == nil, "the intent was taken back")
    }

    @Test func theSettingsListWinsThenTheLastUsedAndAMissingListIsNamed() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        r.actions.preferences.reminderListID = "list-home"
        await r.actions.openReminderEditor(r.tasks[0])
        #expect(r.actions.reminderEditor?.draft.containerID == "list-home")
        r.actions.cancelEditor()
        r.actions.preferences.reminderListID = "list-gone"
        r.actions.preferences.reminderListName = "Archive"
        r.actions.preferences.lastReminderListID = "list-home"
        await r.actions.openReminderEditor(r.tasks[0])
        #expect(r.actions.reminderEditor?.draft.containerID == "list-home" && r.actions.reminderEditor?.unavailableList == "Archive")
    }

    @Test func theAlertIsOffUnlessTheSettingIsOnAndNeedsADueDay() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        r.actions.preferences.alertMinute = 9 * 60
        await r.actions.openReminderEditor(r.tasks[0])
        #expect(r.actions.reminderEditor?.draft.alertMinuteOfDay == 540)
        r.actions.cancelEditor()
        await r.actions.openReminderEditor(r.tasks[1])
        #expect(r.actions.reminderEditor?.draft.alertMinuteOfDay == nil, "a task with no due day has no alert")
        r.actions.preferences.alertMinute = nil
        r.actions.cancelEditor()
        await r.actions.openReminderEditor(r.tasks[0])
        #expect(r.actions.reminderEditor?.draft.alertMinuteOfDay == nil)
    }

    // MARK: Undo and removal

    @Test func undoRemovesOnlyWhatWasAddedAndKeepsWhatThePersonChanged() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[0])
        await r.actions.addReminder()
        let bar = try #require(r.actions.undoBar)
        await r.actions.undo(bar)
        #expect(r.fake.removals == 1 && r.fake.allItems.isEmpty && r.actions.undoBar == nil)
        #expect(r.actions.state(of: r.tasks[0]).kind == .none)
        // Added again, then edited in Reminders: undo keeps it.
        await r.actions.openReminderEditor(r.tasks[0])
        await r.actions.addReminder()
        let item = try #require(r.fake.allItems.first)
        r.fake.editExternally(item.itemID, title: "Mine now")
        await r.actions.undo(try #require(r.actions.undoBar))
        #expect(r.fake.allItems.count == 1 && r.fake.removals == 1)
    }

    @Test func removeLaterAsksFirstAndWarnsWhenEdited() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[0])
        await r.actions.addReminder()
        r.actions.dismissUndoBar()
        await r.actions.refresh(tasks: r.tasks, readBack: true)
        let rowID = try #require(r.actions.state(of: r.tasks[0]).rowID)
        let item = try #require(r.fake.allItems.first)
        r.fake.editExternally(item.itemID, title: "Changed there")
        await r.actions.requestRemoval(rowID: rowID)
        let pending = try #require(r.actions.pendingRemoval)
        #expect(pending.preview.edited && r.fake.removals == 0, "asking removes nothing")
        await r.actions.confirmRemoval()
        #expect(r.fake.removals == 1)
        #expect(r.actions.state(of: r.tasks[0]).kind == .none)
    }

    @Test func aLinkedReminderIsNeverRemovedOnlyUnlinked() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        r.fake.seedReminder("Share the slides")
        await r.actions.openReminderEditor(r.tasks[1])
        await r.actions.useExistingReminder()
        let state = r.actions.state(of: r.tasks[1])
        #expect(state.canUnlink && !state.canRemove)
        await r.actions.forget(state)
        #expect(r.fake.removals == 0 && r.fake.allItems.count == 1 && r.actions.state(of: r.tasks[1]).kind == .none)
    }

    @Test func doneInRemindersNeedsTheButtonAndANewDueDayOnlyShowsAMismatch() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[0])
        await r.actions.addReminder()
        let item = try #require(r.fake.allItems.first)
        r.fake.setDueExternally(item.itemID, oct(20))
        await r.actions.refresh(tasks: r.tasks, readBack: true)
        #expect(r.actions.state(of: r.tasks[0]).kind == .dueDiffers(reminder: oct(20), task: oct(16)))
        r.fake.completeExternally(item.itemID)
        await r.actions.refresh(tasks: r.tasks, readBack: true)
        #expect(r.actions.state(of: r.tasks[0]).kind == .doneInReminders)
        let still = try await r.store.tasks(r.meeting).first { $0.id == r.tasks[0].id }
        #expect(still?.status == .open, "the task did not change by itself")
        await r.actions.markDoneHere(r.tasks[0])
        let done = try await r.store.tasks(r.meeting).first { $0.id == r.tasks[0].id }
        #expect(done?.status == .done)
        #expect(r.fake.writes == 1, "nothing but the one add was written")
    }

    // MARK: Follow-up sheet

    @Test func nothingIsTickedAndTheBatchWritesOnlyTheTicked() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openFollowUp(meetingID: r.meeting)
        let sheet = try #require(r.actions.sheet)
        #expect(r.actions.page == .followUp && sheet.ticked.isEmpty && sheet.tasks.count == 3)
        #expect(sheet.tasks.first?.ownerID != nil, "own tasks first")
        r.actions.toggleTick(sheet.tasks[0])
        r.actions.toggleTick(sheet.tasks[2])
        await r.actions.addTicked()
        #expect(r.fake.writes == 2)
        #expect(r.actions.sheet?.ticked.isEmpty == true && r.actions.undoBar?.actionIDs.count == 2)
        await r.actions.undo(try #require(r.actions.undoBar))
        #expect(r.fake.removals == 2 && r.fake.allItems.isEmpty)
    }

    @Test func aBatchSkipsWhatTheListAlreadyHasAndKeepsItTickedWithANote() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        r.fake.seedReminder("Book the supplier visit")
        await r.actions.openFollowUp(meetingID: r.meeting)
        for task in r.actions.sheet?.tasks ?? [] { r.actions.toggleTick(task) }
        await r.actions.addTicked()
        #expect(r.fake.writes == 2)
        let held = try #require((r.actions.sheet?.tasks ?? []).first { $0.text == "Book the supplier visit" })
        if case .duplicate(.existing)? = r.actions.sheet?.notes[held.id] {} else { Issue.record("expected a duplicate note") }
        #expect(r.actions.sheet?.ticked == [held.id])
    }

    // MARK: Calendar

    @Test func withoutFullCalendarAccessAnIcsFileGoesToCalendarAndNothingIsAsked() async throws {
        let r = try await rig(events: .notDetermined)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        var opened: [URL] = []
        r.actions.openFile = { opened.append($0) }
        await r.actions.openFollowUp(meetingID: r.meeting)
        await r.actions.openEventEditor(nil)
        let editor = try #require(r.actions.eventEditor)
        #expect(!editor.direct && editor.calendars.isEmpty && editor.needsTime, "a time or All day is required")
        r.actions.eventEditor?.minuteOfDay = 10 * 60
        await r.actions.addEvent()
        #expect(r.fake.writes == 0 && r.fake.accessRequests.isEmpty, "EventKit is not written and Calendar access is not asked for")
        let file = try #require(opened.first)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("BEGIN:VEVENT") && !text.contains("ATTENDEE"))
        let rows = try await r.store.actions(ofMeeting: r.meeting)
        #expect(rows.count == 1 && rows[0].target == .ics && rows[0].state == .handedOff)
    }

    @Test func withFullCalendarAccessTheEventIsWrittenOnceAndAnEqualOneBlocksTheAdd() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try await r.store.storeDetectedFollowUps([], meetingID: r.meeting)
        let day = oct(20)
        let id = try await r.store.addFollowUp(r.meeting, title: "Follow-up: Weekly sync", day: day, dayInferred: true, minuteOfDay: 600, durationMinutes: 30, source: .detected)
        await r.actions.openFollowUp(meetingID: r.meeting)
        let follow = try #require(r.actions.sheet?.followUps.first { $0.id == id })
        await r.actions.openEventEditor(follow)
        let editor = try #require(r.actions.eventEditor)
        #expect(editor.direct && editor.dayInferred && editor.canAdd && editor.showsFirstWriteNotice)
        await r.actions.addEvent()
        #expect(r.fake.writes == 1 && r.actions.preferences.calendarWriteNoticeShown)
        // The same follow-up again: the ledger stops it.
        await r.actions.openEventEditor(follow)
        await r.actions.addEvent()
        #expect(r.fake.writes == 1)
        // An equal event in the calendar blocks a new follow-up for that day.
        let r2 = try await rig()
        defer { try? FileManager.default.removeItem(at: r2.directory) }
        try await r2.store.storeDetectedFollowUps([], meetingID: r2.meeting)
        let id2 = try await r2.store.addFollowUp(r2.meeting, title: "Follow-up: Weekly sync", day: day, minuteOfDay: 600, durationMinutes: 30, source: .detected)
        r2.fake.seedEvent("Follow-up: Weekly sync", on: day)
        await r2.actions.openFollowUp(meetingID: r2.meeting)
        #expect(r2.actions.sheet?.existing[id2] != nil, "Already in your calendar")
        await r2.actions.openEventEditor(r2.actions.sheet?.followUps.first { $0.id == id2 })
        #expect(r2.actions.eventEditor?.canAdd == false)
        await r2.actions.addEvent()
        #expect(r2.fake.writes == 0)
    }

    @Test func aDismissedFollowUpGoesAwayAndIsNotOffered() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try await r.store.storeDetectedFollowUps([], meetingID: r.meeting)
        let id = try await r.store.addFollowUp(r.meeting, title: "Follow-up", day: oct(20), source: .detected)
        await r.actions.openFollowUp(meetingID: r.meeting)
        await r.actions.dismissFollowUp(try #require(r.actions.sheet?.followUps.first { $0.id == id }))
        #expect(r.actions.sheet?.visibleFollowUps.isEmpty == true)
    }

    // MARK: Email

    @Test func theEmailListsAddressesNoneTickedAndTheButtonsFollowCopyProtection() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        #expect(!r.actions.emailDraftAvailable, "the email draft is held in this release")
        r.actions.emailDraftAvailable = true
        let ana = try #require(try await r.store.entities(.person).first { $0.email == "ana@example.org" })
        try await r.store.setMeetingEntities(r.meeting, role: .attendee, [ana.id])
        await r.actions.openFollowUp(meetingID: r.meeting)
        let email = try #require(r.actions.sheet?.email)
        let draft = try #require(email.current)
        #expect(email.candidates(for: draft).count == 1 && email.chosen(for: draft).isEmpty, "nobody is ticked")
        #expect(draft.plainText.contains("Send the revised budget") && !email.summaryOffered)
        #expect(!FollowUpEmailSummary.isOffered(backend: "onDevice"), "no summary until a backend has been measured")
        r.actions.toggleRecipient(email.candidates(for: draft)[0], draft: draft)
        #expect(r.actions.sheet?.email.chosen(for: draft).map(\.email) == ["ana@example.org"])
        await r.actions.setEmailMode(.perOwner)
        #expect(r.actions.sheet?.email.drafts.count ?? 0 >= 1)
        // With copy protection on, nothing is copied.
        let board = NSPasteboard.general
        let before = board.changeCount
        r.history.preferences = Preferences(defaults: UserDefaults(suiteName: "vauta-actions-test-\(UUID().uuidString)") ?? .standard, legacyInstall: false)
        r.history.preferences?.copyProtection = true
        r.actions.copyEmail(draft, markdown: false)
        #expect(board.changeCount == before, "nothing was copied")
        #expect(!ActionCopyPolicy.emailAllowed(copyProtection: true) && ActionCopyPolicy.writeAllowed(copyProtection: true) && ActionCopyPolicy.writeWarns(copyProtection: true))
    }

    // MARK: Panel card

    @Test func theCardIsOneForBackToBackMeetingsHiddenWhileRecordingAndGoneAfterTwoHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = FollowUpPending(meetingID: 1, readyAt: now.addingTimeInterval(-600), tasks: 4, followUps: 1)
        let b = FollowUpPending(meetingID: 2, readyAt: now.addingTimeInterval(-60), tasks: 2, followUps: 0)
        #expect(FollowUpCard.content([a], now: now, recording: false, enabled: true) == .one(a))
        #expect(FollowUpCard.content([a, b], now: now, recording: false, enabled: true) == .several(count: 2, newest: 2))
        #expect(FollowUpCard.content([a, b], now: now, recording: true, enabled: true) == .hidden, "hidden while recording; the list is kept")
        #expect(FollowUpCard.content([a, b], now: now, recording: false, enabled: false) == .hidden)
        // The card goes 2 hours after the newest minutes (b), for both meetings together; a does not expire on its own.
        #expect(FollowUpCard.content([a, b], now: b.readyAt.addingTimeInterval(2 * 3600 - 1), recording: false, enabled: true) == .several(count: 2, newest: 2))
        #expect(FollowUpCard.content([a, b], now: b.readyAt.addingTimeInterval(2 * 3600), recording: false, enabled: true) == .hidden)
        #expect(FollowUpCard.expiry([a, b]) == b.readyAt.addingTimeInterval(2 * 3600))
        #expect(FollowUpCard.content([a], now: now.addingTimeInterval(2 * 3600), recording: false, enabled: true) == .hidden)
        #expect(FollowUpCard.content([FollowUpPending(meetingID: 3, readyAt: now, tasks: 0, followUps: 0)], now: now, recording: false, enabled: true) == .hidden, "nothing to review")
    }
}
