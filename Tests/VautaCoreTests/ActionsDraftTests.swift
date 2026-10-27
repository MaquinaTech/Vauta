// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Due days, reminder and event drafts: what is written, and that it never shifts with the time zone.
@Suite("Actions: due days and drafts")
struct ActionsDraftTests {
    static let zones = ["Europe/Madrid", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago", "America/Havana", "Asia/Beirut", "Asia/Kolkata"]

    static func task(_ text: String, owner: Int64? = nil, ownerName: String? = nil, dueDay: String? = nil, speaker: Int64? = nil) -> TaskItem {
        TaskItem(id: 1, meetingID: 1, segmentID: 1, t: 0, text: text, ownerID: owner, ownerName: ownerName, due: nil, status: .open, source: "llm",
                 createdAt: .now, meetingTitle: nil, ownerSpeakerID: speaker, dueDay: dueDay.flatMap { DueDay($0) })
    }

    // MARK: DueDay

    @Test func theCivilCalendarAgreesWithFoundation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var day = DueDay(year: 1999, month: 12, day: 25)!
        for _ in 0..<12_000 {
            let date = Date(timeIntervalSince1970: Double(day.epochDay) * 86_400 + 43_200)
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            #expect(c.year == day.year && c.month == day.month && c.day == day.day && c.weekday == day.weekday)
            #expect(DueDay(epochDay: day.epochDay) == day)
            day = day.adding(days: 1)
        }
    }

    @Test func onlyRealDaysParse() {
        #expect(DueDay("2026-10-16")?.string == "2026-10-16")
        #expect(DueDay("2028-02-29") != nil && DueDay("2026-02-29") == nil)
        for bad in ["2026-13-01", "2026-00-10", "2026-04-31", "2026-1-5", "26-10-16", "2026/10/16", "2026-10-16T00:00", "", "٢٠٢٦-١٠-١٦"] {
            #expect(DueDay(bad) == nil, "\(bad)")
        }
    }

    @Test func aDayThatRoundTripsThroughEveryZone() {
        for zone in Self.zones.compactMap(TimeZone.init(identifier:)) {
            var day = DueDay(year: 2026, month: 1, day: 1)!
            for _ in 0..<370 {
                #expect(DueDay.containing(day.startOfDay(in: zone), in: zone) == day, "\(zone.identifier) \(day)")
                day = day.adding(days: 1)
            }
        }
    }

    @Test func theFloatingComponentsNameNoZoneAndNoInstant() {
        let day = DueDay("2026-10-16")!
        let c = day.floatingComponents
        #expect(c.year == 2026 && c.month == 10 && c.day == 16)
        #expect(c.timeZone == nil && c.calendar == nil && c.hour == nil && c.minute == nil && c.era == nil)
        let alert = day.floatingComponents(minuteOfDay: 9 * 60)
        #expect(alert.hour == 9 && alert.minute == 0 && alert.timeZone == nil)
    }

    // MARK: The due day written by the reminder path, in every zone

    /// The validator reads the minutes under Madrid; the reminder path writes under the other zones; the written day must be the
    /// minutes' day string, compared with an independent parse of the string.
    @Test func theMinutesDayIsWrittenUnchangedInEveryZone() throws {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        let meeting = DueDay(year: 2026, month: 10, day: 12)!.startOfDay(in: madrid).addingTimeInterval(11 * 3600)
        let segments: [Int64: CitableSegment] = [
            10: CitableSegment(id: 10, channel: .others, start: 60, text: "Ana, can you send the revised budget before Friday the sixteenth of October?"),
        ]
        let candidates = [CandidateEntity(id: 1, kind: .person, name: "Yo", aliases: []), CandidateEntity(id: 5, kind: .person, name: "Ana", aliases: [])]
        for written in ["2026-10-16", "2027-03-28", "2026-10-25", "2027-01-01"] {
            let json = """
                {"decisions": [], "entities": [], "tasks": [{"text": "Ana sends the revised budget", "owner": "Ana", "due": "\(written)", "seg": 10, "quote": "send the revised budget"}]}
                """
            let minutes = try VautaPrompts.validateMinutes(json, segments: segments, candidates: candidates, selfEntity: 1, meetingPeople: [5],
                                                           reference: meeting, timeZone: madrid)
            let task = try #require(minutes.tasks.first)
            #expect(task.dueDay?.string == written, "the validator keeps the day the model wrote")
            let parts = written.split(separator: "-").compactMap { Int($0) }
            for name in Self.zones {
                let zone = TimeZone(identifier: name)!
                let draft = ReminderDraft(title: "x", containerID: "L", dueDay: task.dueDay)
                let due = try #require(draft.write().due)
                #expect([due.year, due.month, due.day] == parts.map { Optional($0) }, "\(written) in \(name)")
                #expect(due.timeZone == nil && due.calendar == nil)
                // Whatever zone the person is in when Reminders reads the components, it is that day there.
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                let date = try #require(calendar.date(from: due))
                let read = calendar.dateComponents([.year, .month, .day], from: date)
                #expect([read.year, read.month, read.day] == parts.map { Optional($0) }, "\(written) read in \(name)")
            }
        }
    }

    @Test func theEmailWritesTheStoredDayInEveryLocaleWithoutAZone() {
        let day = DueDay("2026-10-16")!
        #expect(day.formatted(locale: Locale(identifier: "en_US")) == "Friday, October 16")
        #expect(day.formatted(locale: Locale(identifier: "es_ES")).contains("16") && day.formatted(locale: Locale(identifier: "es_ES")).lowercased().contains("viernes"))
        #expect(day.formatted(locale: Locale(identifier: "de_DE")).contains("16") && day.formatted(locale: Locale(identifier: "de_DE")).contains("Freitag"))
        #expect(day.shortFormatted(locale: Locale(identifier: "en_US")) == "Oct 16")
        let edge = DueDay("2026-12-31")!
        #expect(edge.formatted(locale: Locale(identifier: "en_US")) == "Thursday, December 31")
    }

    // MARK: Reminder drafts

    @Test func noAlertByDefaultAndAFloatingNineOclockAlarmWhenAsked() {
        let day = DueDay("2026-10-16")
        let plain = ReminderDraft(title: "x", containerID: "L", dueDay: day).write()
        #expect(plain.alert == false && plain.due?.hour == nil)
        let alert = ReminderDraft(title: "x", containerID: "L", dueDay: day, alertMinuteOfDay: ReminderDraft.defaultAlertMinute).write()
        #expect(alert.alert && alert.due?.hour == 9 && alert.due?.minute == 0 && alert.due?.timeZone == nil)
        let none = ReminderDraft(title: "x", containerID: "L", dueDay: nil, alertMinuteOfDay: 540).write()
        #expect(none.alert == false && none.due == nil, "no day, no alarm")
    }

    @Test func titlesCarryTheOwnerOfSomeoneElsesTaskOneLineAndAtMost300Characters() {
        #expect(ReminderDraft.title(for: Self.task("Send the revised budget", owner: 7, ownerName: "Ana"), selfEntityID: 1) == "Ana: Send the revised budget")
        #expect(ReminderDraft.title(for: Self.task("Send it", owner: 1, ownerName: "Maya"), selfEntityID: 1) == "Send it", "the person's own task has no prefix")
        #expect(ReminderDraft.title(for: Self.task("Send it"), selfEntityID: 1) == "Send it", "no owner, no prefix")
        #expect(ReminderDraft.title(for: Self.task("Send it", ownerName: "Speaker 2", speaker: 4), selfEntityID: 1) == "Send it", "a speaker label is not a name")
        #expect(ReminderDraft.title(for: Self.task("Line one\nline two\t<<<x>>>"), selfEntityID: nil) == "Line one line two ‹‹‹x›››")
        let long = ReminderDraft.title(for: Self.task(String(repeating: "word ", count: 200), owner: 7, ownerName: "Ana"), selfEntityID: 1)
        #expect(long.count == 300 && long.hasPrefix("Ana: "))
        let written = ReminderDraft(title: "  a\nb  ", containerID: "L", dueDay: nil).write().title
        #expect(written == "a b", "whatever the editor holds, one clean line")
    }

    @Test func theNotesNameTheMeetingOrOnlyItsDateAndNeverHoldTranscriptText() {
        let task = Self.task("Send it", dueDay: "2026-10-16")
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let named = ReminderDraft.make(task: task, selfEntityID: nil, containerID: "L", meetingTitle: "Weekly sync", meetingDate: date)
        #expect(named.notes?.contains("Weekly sync") == true)
        let anonymous = ReminderDraft.make(task: task, selfEntityID: nil, containerID: "L", meetingTitle: "Weekly sync", meetingDate: date, includeMeetingName: false)
        #expect(anonymous.notes?.contains("Weekly sync") == false)
        #expect(named.dueDay?.string == "2026-10-16")
    }

    @Test func theSheetListsTheUsersOwnTasksFirstThenUnownedThenByOwner() {
        let mine = TaskItem(id: 3, meetingID: 1, segmentID: nil, t: nil, text: "mine", ownerID: 1, ownerName: "Me", due: nil, status: .open, source: "llm", createdAt: .now, meetingTitle: nil)
        let ana = TaskItem(id: 4, meetingID: 1, segmentID: nil, t: nil, text: "ana", ownerID: 7, ownerName: "Ana", due: nil, status: .open, source: "llm", createdAt: .now, meetingTitle: nil)
        let bo = TaskItem(id: 5, meetingID: 1, segmentID: nil, t: nil, text: "bo", ownerID: 8, ownerName: "Bo", due: nil, status: .open, source: "llm", createdAt: .now, meetingTitle: nil)
        let nobody = TaskItem(id: 6, meetingID: 1, segmentID: nil, t: nil, text: "nobody", ownerID: nil, ownerName: nil, due: nil, status: .open, source: "llm", createdAt: .now, meetingTitle: nil)
        #expect(ActionOrdering.sheetOrder([bo, nobody, ana, mine], selfEntityID: 1).map(\.text) == ["mine", "nobody", "ana", "bo"])
    }

    // MARK: Event drafts

    @Test func eventDurationIsTheMeetingsRoundedToQuartersBetween15And60Else30() {
        #expect(EventDraft.duration(ofMeeting: nil) == 30)
        #expect(EventDraft.duration(ofMeeting: 20 * 60) == 15)
        #expect(EventDraft.duration(ofMeeting: 50 * 60) == 45)
        #expect(EventDraft.duration(ofMeeting: 55 * 60) == 60)
        #expect(EventDraft.duration(ofMeeting: 3 * 3600) == 30, "longer than an hour: 30")
        #expect(EventDraft.duration(ofMeeting: 4 * 60) == 30, "shorter than a quarter: 30")
    }

    @Test func anEventWithATimeIsWrittenInTheMeetingsZoneAndAnAllDayOneHasNone() throws {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        let draft = EventDraft(title: "Follow-up", containerID: "C", day: DueDay("2026-10-21")!, minuteOfDay: 600, durationMinutes: 30, timeZone: madrid)
        let interval = try #require(draft.interval)
        #expect(interval.start == Date(timeIntervalSince1970: 1_792_569_600), "10:00 in Madrid (UTC+2 on 21 October) is 08:00 UTC")
        #expect(interval.duration == 1_800)
        let allDay = EventDraft(title: "Follow-up", containerID: "C", day: DueDay("2026-10-21")!, minuteOfDay: nil, durationMinutes: 30, timeZone: madrid)
        #expect(allDay.interval == nil && allDay.write().isAllDay)
    }
}
