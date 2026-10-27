// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class RoundKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// Third review: the removal title without a calendar name, the list a reminder starts in, an event deleted in Calendar, the batch's
/// count, the event's notes. Fake writer only: nothing here reaches Reminders, Calendar or Mail.
@Suite("Actions: third review fixes")
@MainActor
struct ActionsRound3Tests {
    struct Rig {
        let directory: URL
        let store: MeetingStore
        let actions: ActionsModel
        let fake: FakeActionWriter
        let meeting: Int64
        let tasks: [TaskItem]
    }

    private func rig(events: ActionAccess = .full) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-round3-\(UUID().uuidString)", isDirectory: true)
        let store = try MeetingStore(directory: directory, keyStore: RoundKey())
        let start = Date(timeIntervalSince1970: 1_791_450_000)
        let meeting = try await store.startMeeting(at: start)
        try await store.setTitle("Weekly sync", of: meeting)
        let segment = try await store.append(Segment(channel: .others, start: 40, end: 50, text: "Let's meet again next Tuesday", isFinal: true), to: meeting)
        _ = try await store.addTask(meeting, text: "Send the revised budget", segmentID: segment, t: 40)
        _ = try await store.addTask(meeting, text: "Share the slides", segmentID: segment, t: 41)
        _ = try await store.addTask(meeting, text: "Book the supplier visit", segmentID: segment, t: 42)
        try await store.endMeeting(meeting, at: start.addingTimeInterval(1800))
        let history = MeetingsModel(store: store)
        let fake = FakeActionWriter()
        fake.setAccess(.event, events)
        history.actions.use(writer: fake)
        history.actions.bringToFront = {}
        history.actions.preferences = ActionsPreferences(defaults: UserDefaults(suiteName: "vauta-round3-test-\(UUID().uuidString)") ?? .standard)
        history.actions.caches = directory.appendingPathComponent("caches", isDirectory: true)
        history.actions.openFile = { _ in }
        let tasks = try await store.tasks(meeting)
        return Rig(directory: directory, store: store, actions: history.actions, fake: fake, meeting: meeting, tasks: tasks)
    }

    private func addFollowUpEvent(_ r: Rig) async throws -> FollowUp {
        try await r.store.storeDetectedFollowUps([], meetingID: r.meeting)
        let id = try await r.store.addFollowUp(r.meeting, title: "Follow-up: Weekly sync", day: DueDay(year: 2026, month: 10, day: 20)!, minuteOfDay: 600,
                                                durationMinutes: 30, source: .detected)
        await r.actions.openFollowUp(meetingID: r.meeting)
        let follow = try #require(r.actions.sheet?.followUps.first { $0.id == id })
        await r.actions.openEventEditor(follow)
        await r.actions.addEvent()
        r.actions.dismissUndoBar()
        return follow
    }

    @Test func removingAnEventNamesItsCalendarEvenWhenTheMeetingHasNoReminder() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let follow = try await addFollowUpEvent(r)
        r.actions.containerNames = [:]   // no reminder row made the names load
        await r.actions.requestEventRemoval(follow)
        let pending = try #require(r.actions.pendingRemoval)
        #expect(pending.listName == "Work · iCloud", "the confirmation names the calendar: \(pending.listName)")
    }

    @Test func anEventDeletedInCalendarIsASuggestionAgainWhenTheSheetOpens() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let follow = try await addFollowUpEvent(r)
        await r.actions.openFollowUp(meetingID: r.meeting)
        #expect(r.actions.sheet?.events[follow.id] != nil, "added")
        let item = try #require(r.fake.allItems.first)
        r.fake.deleteExternally(item.itemID)
        await r.actions.openFollowUp(meetingID: r.meeting)
        #expect(r.actions.sheet?.events[follow.id] == nil, "no longer 'Added to Calendar'")
        #expect(r.actions.sheet?.followUps.first { $0.id == follow.id }?.state == .suggested)
        #expect(r.fake.removals == 0, "nothing was removed or written to find out")
    }

    @Test func withoutCalendarAccessNothingIsLookedUp() async throws {
        let r = try await rig(events: .notDetermined)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        try await r.store.storeDetectedFollowUps([], meetingID: r.meeting)
        let id = try await r.store.addFollowUp(r.meeting, title: "Follow-up", day: DueDay(year: 2026, month: 10, day: 20)!, minuteOfDay: 600, durationMinutes: 30, source: .detected)
        let intent = try await r.store.beginAction(target: .event, source: .followUp, sourceID: id, containerID: "cal-work", titleHash: "h")
        try await r.store.completeAction(intent.action.id, itemID: "gone", externalID: nil)
        await r.actions.openFollowUp(meetingID: r.meeting)
        #expect(try await r.store.action(intent.action.id)?.state == .created, "not concluded from not being able to look")
    }

    @Test func noListChosenInSettingsStartsInTheLastUsedThenTheSystemDefault() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.refreshAccess(names: true)
        let lists = await r.fake.containers(.reminder)
        r.actions.preferences.lastReminderListID = "list-home"
        #expect(await r.actions.chooseList(among: lists).id == "list-home", "the label says: last used, else Reminders' default")
        r.actions.preferences.lastReminderListID = nil
        #expect(await r.actions.chooseList(among: lists).id == "list-work", "the system default until a list was used")
        r.actions.preferences.reminderListID = "list-work"
        r.actions.preferences.lastReminderListID = "list-home"
        #expect(await r.actions.chooseList(among: lists).id == "list-work", "a list chosen in Settings wins")
    }

    @Test func aRowWithAnUnresolvedDuplicateIsNotCountedByTheBatchButtonOrAddedAgain() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        r.fake.seedReminder("Book the supplier visit")
        await r.actions.openFollowUp(meetingID: r.meeting)
        for task in r.actions.sheet?.tasks ?? [] { r.actions.toggleTick(task) }
        #expect(r.actions.sheet?.addableTicked.count == 3)
        await r.actions.addTicked()
        #expect(r.fake.writes == 2)
        #expect(r.actions.sheet?.ticked.count == 1 && r.actions.sheet?.addableTicked.isEmpty == true, "the button counts 0: the row waits for Use This One or Add Anyway")
        await r.actions.addTicked()
        #expect(r.fake.writes == 2, "pressing again adds nothing")
        if case .duplicate? = r.actions.sheet?.notes[r.actions.sheet?.ticked.first ?? -1] {} else { Issue.record("the banner stays") }
    }

    @Test func aBatchBarSaysHowManyWereAdded() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openFollowUp(meetingID: r.meeting)
        for task in (r.actions.sheet?.tasks ?? []).prefix(2) { r.actions.toggleTick(task) }
        await r.actions.addTicked()
        let two = try #require(r.actions.undoBar)
        #expect(two.text.contains("2") && two.actionIDs.count == 2, "\(two.text)")
        r.actions.dismissUndoBar()
        for task in (r.actions.sheet?.tasks ?? []) where r.actions.state(of: task).kind == .none { r.actions.toggleTick(task) }
        await r.actions.addTicked()
        let one = try #require(r.actions.undoBar)
        #expect(!one.text.contains("1") && one.actionIDs.count == 1, "a single add keeps the plain wording: \(one.text)")
    }

    @Test func theMeetingNameSettingAppliesToEventNotesAndTheIcsFile() async throws {
        let r = try await rig(events: .notDetermined)
        defer { try? FileManager.default.removeItem(at: r.directory) }
        r.actions.preferences.includeMeetingName = false
        var opened: [URL] = []
        r.actions.openFile = { opened.append($0) }
        await r.actions.openFollowUp(meetingID: r.meeting)
        await r.actions.openEventEditor(nil)
        r.actions.eventEditor?.minuteOfDay = 600
        let notes = try #require(r.actions.eventEditor?.draft.write().notes)
        #expect(!notes.contains("Weekly sync"), "\(notes)")
        await r.actions.addEvent()
        let text = try String(contentsOf: try #require(opened.first), encoding: .utf8)
        let description = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("DESCRIPTION:") })
        #expect(!description.contains("Weekly sync"), "the file's description follows the notes: \(description)")
        let withName = EventDraft.make(title: "T", day: DueDay(year: 2026, month: 10, day: 20)!, minuteOfDay: 600, durationMinutes: 30, containerID: "c",
                                       meetingTitle: "Weekly sync", meetingDate: .now, timeZone: .current)
        #expect(withName.notes?.contains("Weekly sync") == true, "kept by default")
    }
}
