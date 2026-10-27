// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class RecoveryKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// What the Meetings window does around an interrupted write, a slow refresh and a ticked task. Fake writer, temporary store.
@Suite("Actions: recovery in the window")
@MainActor
struct ActionsModelRecoveryTests {
    struct Rig {
        let directory: URL
        let store: MeetingStore
        let actions: ActionsModel
        let fake: FakeActionWriter
        let meeting: Int64
        let tasks: [TaskItem]
    }

    private func rig() async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-recovery-\(UUID().uuidString)", isDirectory: true)
        let store = try MeetingStore(directory: directory, keyStore: RecoveryKey())
        let start = Date(timeIntervalSince1970: 1_791_450_000)
        let meeting = try await store.startMeeting(at: start)
        try await store.setTitle("Weekly sync", of: meeting)
        let segment = try await store.append(Segment(channel: .others, start: 40, end: 50, text: "We need the budget and the slides", isFinal: true), to: meeting)
        _ = try await store.addTask(meeting, text: "Send the revised budget", segmentID: segment, t: 40)
        _ = try await store.addTask(meeting, text: "Share the slides", segmentID: segment, t: 41)
        try await store.endMeeting(meeting, at: start.addingTimeInterval(1800))
        let history = MeetingsModel(store: store)
        let fake = FakeActionWriter()
        history.actions.use(writer: fake)
        history.actions.bringToFront = {}
        history.actions.preferences = ActionsPreferences(defaults: UserDefaults(suiteName: "vauta-recovery-test-\(UUID().uuidString)") ?? .standard)
        history.actions.caches = directory.appendingPathComponent("caches", isDirectory: true)
        history.actions.openFile = { _ in }
        return Rig(directory: directory, store: store, actions: history.actions, fake: fake, meeting: meeting, tasks: try await store.tasks(meeting))
    }

    private func deadIntent(_ r: Rig, task: TaskItem, saved: Bool) async throws {
        let draft = ReminderDraft.make(task: task, selfEntityID: nil, containerID: "list-work", meetingTitle: "Weekly sync", meetingDate: Date(timeIntervalSince1970: 1_791_450_000))
        _ = try await r.store.beginAction(target: .reminder, source: .task, sourceID: task.id, containerID: "list-work", titleHash: draft.titleHash)
        if saved { _ = try await r.fake.addReminder(draft.write()) }
    }

    @Test func aDeadIntentWithNothingSavedLeavesTheEditorAbleToAdd() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try await deadIntent(r, task: r.tasks[0], saved: false)
        await r.actions.openReminderEditor(r.tasks[0])
        #expect(r.actions.reminderEditor?.finding == DuplicateFinding.none)
        #expect(r.actions.reminderEditor?.canAdd == true, "Add is not disabled for good")
        await r.actions.addReminder()
        #expect(r.fake.writes == 1)
    }

    @Test func aDeadIntentWhoseReminderWasSavedShowsInRemindersAfterTheWindowRefreshes() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try await deadIntent(r, task: r.tasks[0], saved: true)
        await r.actions.refresh(tasks: r.tasks, readBack: true)
        #expect(r.actions.state(of: r.tasks[0]).kind == .inReminders, "settled when the surface opens, not shown as nothing")
        #expect(r.actions.state(of: r.tasks[0]).itemID != nil)
        #expect(try await r.store.writingActions().isEmpty)
        #expect(r.fake.writes == 1)
    }

    @Test func aRefreshThatStartedBeforeAnAddNeverErasesItsStatus() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[0])
        async let slow: Void = r.actions.refresh(tasks: r.tasks, readBack: true)
        async let add: Void = r.actions.addReminder()
        _ = await (slow, add)
        await r.actions.refresh(tasks: r.tasks, readBack: true)
        #expect(r.actions.state(of: r.tasks[0]).kind == .inReminders)
        #expect(r.fake.writes == 1)
    }

    @Test func aTaskAddedThroughEditIsNoLongerTickedInTheSheet() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openFollowUp(meetingID: r.meeting)
        let task = try #require(r.actions.sheet?.tasks.first)
        r.actions.toggleTick(task)
        #expect(r.actions.sheet?.ticked == [task.id])
        await r.actions.openReminderEditor(task, fromFollowUp: true)
        await r.actions.addReminder()
        #expect(r.actions.page == .followUp && r.actions.sheet?.ticked.isEmpty == true, "the button no longer counts a task that is already there")
    }

    @Test func returnInAnEmptyTitleAddsNothing() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[0])
        r.actions.reminderEditor?.draft.title = "   "
        await r.actions.addReminder()
        #expect(r.fake.writes == 0 && r.actions.reminderEditor != nil)
    }

    @Test func openingTheSheetTellsThePanelItsCardIsReviewed() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        var opened: [Int64] = []
        r.actions.onFollowUpOpened = { opened.append($0) }
        await r.actions.openFollowUp(meetingID: r.meeting)
        #expect(opened == [r.meeting])
    }

    @Test func theSheetChecksForFollowUpsOnlyWhenDetectionIsOn() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        // The shipped value, written out: turning detection off (or on) is a decision that changes this line.
        #expect(ActionsRelease.followUpDetection == true)
        #expect(r.actions.followUpDetectionAvailable)
        await r.actions.openFollowUp(meetingID: r.meeting)
        let recipe = try await r.store.followUpsRecipe(r.meeting)
        #expect(recipe != 0, "the meeting was searched, so an empty list says the search found nothing")
    }
}
