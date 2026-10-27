// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class ReviewKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// Fixes from the review: the Tasks table's due day, the status refresh, the drafts kept across the Follow-up sheet. Fake writer only.
@Suite("Actions: review fixes in the app")
@MainActor
struct ActionsReviewFixAppTests {
    struct Rig {
        let directory: URL
        let history: MeetingsModel
        let actions: ActionsModel
        let fake: FakeActionWriter
        let meeting: Int64
        let tasks: [TaskItem]
    }

    private func rig() async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-review-\(UUID().uuidString)", isDirectory: true)
        let store = try MeetingStore(directory: directory, keyStore: ReviewKey())
        let start = Date(timeIntervalSince1970: 1_791_450_000)
        let meeting = try await store.startMeeting(at: start)
        try await store.setTitle("Weekly sync", of: meeting)
        let segment = try await store.append(Segment(channel: .others, start: 40, end: 50, text: "We agreed", isFinal: true), to: meeting)
        let day = DueDay(year: 2026, month: 10, day: 16)!
        _ = try await store.addTask(meeting, text: "Send the revised budget", due: day.startOfDay(in: .current), dueDay: day, segmentID: segment, t: 40)
        _ = try await store.addTask(meeting, text: "Share the slides", segmentID: segment, t: 41)
        _ = try await store.addTask(meeting, text: "Book the supplier visit", segmentID: segment, t: 42)
        try await store.endMeeting(meeting, at: start.addingTimeInterval(1800))
        let history = MeetingsModel(store: store)
        let fake = FakeActionWriter()
        history.actions.use(writer: fake)
        history.actions.bringToFront = {}
        history.actions.preferences = ActionsPreferences(defaults: UserDefaults(suiteName: "vauta-review-test-\(UUID().uuidString)") ?? .standard)
        let tasks = try await store.tasks(meeting)
        return Rig(directory: directory, history: history, actions: history.actions, fake: fake, meeting: meeting, tasks: tasks)
    }

    // MARK: The Due column

    @Test func theDueColumnWritesTheDayTheTaskSaysInAnyZone() {
        let day = DueDay(year: 2026, month: 10, day: 16)!
        let now = Date(timeIntervalSince1970: 1_791_450_000)   // 8 Oct 2026
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let text = TaskDueFormat.text(day, now: now, zone: la, locale: Locale(identifier: "en_US"))
        #expect(text == "Oct 16", "not the 15th, which is what the stored instant is in Los Angeles: \(text)")
        #expect(TaskDueFormat.text(DueDay(year: 2027, month: 1, day: 5)!, now: now, zone: la, locale: Locale(identifier: "en_US")) == "Jan 5, 2027")
    }

    @Test func overdueAndTodayAreComparedByCalendarDay() {
        let day = DueDay(year: 2026, month: 10, day: 16)!
        #expect(TaskDueFormat.marks(day: day, open: true, today: DueDay(year: 2026, month: 10, day: 16)!) == (false, true))
        #expect(TaskDueFormat.marks(day: day, open: true, today: DueDay(year: 2026, month: 10, day: 17)!) == (true, false))
        #expect(TaskDueFormat.marks(day: day, open: true, today: DueDay(year: 2026, month: 10, day: 15)!) == (false, false), "not late a day early")
        #expect(TaskDueFormat.marks(day: day, open: false, today: DueDay(year: 2026, month: 10, day: 17)!) == (false, false))
    }

    // MARK: Refreshing the status

    @Test func aRefreshThatReadTheLedgerBeforeAnAddCannotEraseTheAdd() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let task = r.tasks[0]
        // The slow refresh has read the ledger (nothing yet) when the Add runs to the end, including its own refresh.
        var ran = false
        r.actions.refreshProbe = { [weak actions = r.actions] in
            guard !ran, let actions else { return }
            ran = true
            actions.refreshProbe = nil
            await actions.openReminderEditor(task)
            await actions.addReminder()
        }
        await r.actions.refresh(tasks: r.tasks, readBack: true)
        #expect(ran)
        #expect(r.actions.state(of: task).kind == .inReminders, "the status the Add wrote is still there")
        #expect(r.fake.writes == 1)
    }

    // MARK: Drafts

    @Test func openingTheFollowUpSheetKeepsADraftOfThisMeeting() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        await r.actions.openReminderEditor(r.tasks[0])
        r.actions.reminderEditor?.draft.title = "My own wording"
        r.actions.dismissedExternally()
        #expect(r.actions.page == nil && r.actions.reminderEditor != nil)
        await r.actions.openFollowUp(meetingID: r.meeting)
        #expect(r.actions.reminderEditor?.draft.title == "My own wording", "what was typed is still there")
        let other = try await r.history.store.startMeeting(at: Date(timeIntervalSince1970: 1_791_500_000))
        _ = try await r.history.store.append(Segment(channel: .others, start: 1, end: 2, text: "Hello", isFinal: true), to: other)
        try await r.history.store.endMeeting(other, at: Date(timeIntervalSince1970: 1_791_501_000))
        await r.actions.openFollowUp(meetingID: other)
        #expect(r.actions.reminderEditor == nil, "a draft of another meeting goes")
    }
}
