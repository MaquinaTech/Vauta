// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `weekDigest`: the week of the person's calendar (its first day and its time zone), and what the store says it held.
@Suite("Knowledge: the week's digest")
struct WeekDigestTests {
    private static let madrid = TimeZone(identifier: "Europe/Madrid")!

    private static func calendar(firstWeekday: Int = 2) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = madrid
        c.locale = Locale(identifier: "en_GB")   // before the first weekday: setting a locale sets its own
        c.firstWeekday = firstWeekday
        return c
    }

    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar().date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func meeting(_ store: MeetingStore, at start: Date, title: String) async throws -> Int64 {
        let id = try await store.startMeeting(at: start, timeZone: Self.madrid)
        try await store.append(Segment(channel: .others, start: 0, end: 5, text: "We talked", isFinal: true), to: id)
        _ = try await store.endMeeting(id, at: start + 1_800)
        try await store.execForTests("UPDATE meetings SET title = ? WHERE id = ?", [.text(title), .integer(id)])
        return id
    }

    private func item(_ store: MeetingStore, _ sql: String, _ params: [SQLiteValue?]) async throws -> Int64 {
        try await store.execForTests(sql, params)
        return try #require(try await store.intsForTests("SELECT last_insert_rowid()").first)
    }

    @Test func theWeekIsThePersonsAndHoldsWhatTheStoreSays() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let before = try await meeting(store, at: Self.at(25, 23, 30), title: "Sunday before")   // the week before, in Madrid
        let monday = try await meeting(store, at: Self.at(26, 10), title: "Weekly sync")
        let sunday = try await meeting(store, at: Self.at(1, 23, 30, month: 11), title: "Late Sunday")
        _ = try await meeting(store, at: Self.at(2, 0, 30, month: 11), title: "Next week")
        let firm = try await item(store, "INSERT INTO decisions(meeting_id, t, text, source, created_at) VALUES (?, 1, 'Ship on Friday', 'llm', 0)", [.integer(monday)])
        _ = try await item(store, "INSERT INTO decisions(meeting_id, t, text, source, created_at, unconfirmed, unconfirmed_reason) VALUES (?, 2, 'Maybe later', 'llm', 0, 1, 'rank')",
                           [.integer(monday)])
        _ = try await item(store, "INSERT INTO decisions(meeting_id, t, text, source, created_at) VALUES (?, 1, 'Old news', 'llm', 0)", [.integer(before)])
        try await store.saveCard(MeetingCard(summary: "Sync", topics: [], openQuestions: ["Who pays?"]), of: sunday)
        func task(_ text: String, created: Date, status: String = "open", done: Date? = nil, due: String? = nil) async throws -> Int64 {
            try await item(store, "INSERT INTO tasks(meeting_id, t, text, status, source, created_at, done_at, due_day) VALUES (?, 1, ?, ?, 'llm', ?, ?, ?)",
                           [.integer(monday), .text(text), .text(status), .real(created.timeIntervalSince1970),
                            done.map { .real($0.timeIntervalSince1970) }, due.map { .text($0) }])
        }
        let added = try await task("Send the report", created: Self.at(26, 11))
        let finished = try await task("Book the room", created: Self.at(20, 9), status: "done", done: Self.at(27, 9))
        let late = try await task("Pay the invoice", created: Self.at(19, 9), due: "2026-10-20")
        _ = try await task("Dropped idea", created: Self.at(26, 12), status: "dropped")
        _ = try await task("Due today", created: Self.at(19, 9), due: "2026-10-28")

        let digest = try await store.weekDigest(containing: Self.at(28, 15), calendar: Self.calendar(), now: Self.at(28, 15))
        #expect(digest.week.start == Self.at(26, 0) && digest.week.end == Self.at(2, 0, month: 11), "Monday to Monday, in Madrid")
        #expect(digest.meetings.map(\.displayTitle) == ["Weekly sync", "Late Sunday"])
        #expect(digest.decisions.map(\.id) == [firm], "not one the minutes ranked out, nor one of another week")
        #expect(digest.tasksAdded.map(\.id) == [added], "not one dropped")
        #expect(digest.tasksDone.map(\.id) == [finished], "done in the week, though added before it")
        #expect(digest.tasksOverdue.map(\.id) == [late], "a day before today; today is not late")
        #expect(digest.openQuestions == [.init(meetingID: sunday, text: "Who pays?")])
        #expect(digest.meetingTitle(monday) == "Weekly sync")

        let markdown = digest.markdown(calendar: Self.calendar())
        #expect(markdown.hasPrefix("# Week of "))
        #expect(markdown.contains("## Decisions\n\n- Ship on Friday — Weekly sync\n"))
        #expect(markdown.contains("- [x] Book the room"))
        #expect(markdown.contains("- [ ] Pay the invoice — due "))
        #expect(markdown.contains("## Open questions\n\n- Who pays? — Late Sunday\n"))
    }

    @Test func aWeekThatStartsOnSundayStartsOnSunday() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let sunday = try await meeting(store, at: Self.at(25, 23, 30), title: "Sunday")
        let digest = try await store.weekDigest(containing: Self.at(28, 15), calendar: Self.calendar(firstWeekday: 1), now: Self.at(28, 15))
        #expect(digest.week.start == Self.at(25, 0))
        #expect(digest.meetings.map(\.id) == [sunday])
    }

    @Test func anEmptyWeekSaysSo() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let digest = try await store.weekDigest(containing: Self.at(28, 15), calendar: Self.calendar(), now: Self.at(28, 15))
        #expect(digest.isEmpty)
        #expect(digest.markdown(calendar: Self.calendar()).contains("Nothing was recorded this week."))
    }
}
