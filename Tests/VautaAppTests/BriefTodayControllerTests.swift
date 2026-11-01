// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// Meetings › Upcoming › Today, through the controller: the day's events are read when the list opens, a meeting's brief is built only
/// when it is opened, and locking Meetings drops both.
@MainActor
@Suite("Brief: Today in Upcoming")
struct BriefTodayControllerTests {
    /// Meetings for the brief's own reads; every event of the day for Today's.
    struct DaySource: BriefEventSource {
        let all: [BriefEvent]
        func events(from: Date, to: Date, calendarIDs: Set<String>) async -> [BriefEvent] {
            all.filter { calendarIDs.contains($0.calendarID) && !$0.isAllDay && $0.start < to && $0.end > from }
        }
        func dayEvents(from: Date, to: Date, calendarIDs: Set<String>, limit: Int) async -> [BriefEvent] {
            Array(all.filter { calendarIDs.contains($0.calendarID) && $0.start < to && $0.end > from }.prefix(limit))
        }
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(240)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func theDayIsReadWhenShownABriefIsBuiltWhenOpenedAndLockingDropsBoth() async throws {
        let now = Date.now
        // On now, so it is today's whatever the time (it may have started yesterday, just after midnight).
        let meeting = BriefEvent(identifier: "evt-1", title: "Supplier review", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(3_000), calendarID: "work",
                                 attendees: [BriefAttendee(name: "Me", email: nil, isCurrentUser: true), BriefAttendee(name: "Ana López", email: nil)], service: .zoom)
        let day = Calendar.current.startOfDay(for: now)
        let holiday = BriefEvent(identifier: "hol", title: "Holiday", start: day, end: day.addingTimeInterval(86_400), calendarID: "work", isAllDay: true)
        let other = BriefEvent(identifier: "bday", title: "Birthday", start: day, end: day.addingTimeInterval(86_400), calendarID: "birthdays", isAllDay: true)
        let suite = "vauta-brief-today-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = BriefController(defaults: defaults)
        controller.prefs.hintSeen = true
        controller.prefs.enabled = true
        let builds = BriefControllerTests.BuildCount()
        let lock = BriefControllerTests.Lock(false)
        controller.seams = BriefController.Seams(isLocked: { lock.locked }, source: DaySource(all: [meeting, holiday, other]),
                                                 build: { event, _ in
                                                     builds.add()
                                                     return BriefController.Entry(event: event, snapshot: BriefControllerTests.snapshot(event))
                                                 },
                                                 isRecording: { false })

        #expect(controller.today == .off && builds.count == 0, "nothing is read before the list is shown")
        controller.openToday()
        #expect(await until { if case .items = controller.today { return true }; return false })
        guard case .items(let items) = controller.today else { return }
        #expect(items.map(\.event.title) == ["Holiday", "Supplier review"], "the chosen calendars only, all-day first")
        #expect(items.map(\.hasBrief) == [false, true] && items[1].moment == .now)
        #expect(builds.count == 0, "listing the day builds no brief")

        controller.openTodayBrief(items[0])
        #expect(controller.todayEntry == nil, "an event with no brief opens nothing")
        controller.openTodayBrief(items[1])
        #expect(await until { controller.todayEntry?.snapshot != nil })
        #expect(controller.todayEntry?.event.occurrence == meeting.occurrence && builds.count == 1)
        controller.closeTodayBrief()
        #expect(controller.todayEntry == nil)

        controller.openTodayBrief(items[1])
        #expect(await until { controller.todayEntry?.snapshot != nil })
        lock.locked = true
        controller.locked()
        #expect(controller.todayEntry == nil && controller.today == .loading, "locked: nothing of today stays in memory")
    }
}
