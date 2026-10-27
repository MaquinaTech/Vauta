// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// Invented events, retrieval and reminders for the brief tests: no EventKit, no model, no real store but the throwaway one.
enum BriefFixtures {
    /// 2026-10-19 09:00 UTC-ish; only differences matter.
    static let now = Date(timeIntervalSince1970: 1_792_400_000)
    static let rules = BriefEventRules(calendarIDs: ["work"])

    static func event(_ id: String = "evt-1", title: String = "Supplier review", in minutes: Double = 10, length: Double = 60, calendar: String = "work",
                      attendees: [BriefAttendee]? = nil, service: ConferencingService? = .zoom, recurring: Bool = false, declined: Bool = false,
                      allDay: Bool = false, notes: String? = nil, at base: Date = now) -> BriefEvent {
        BriefEvent(identifier: id, title: title, start: base.addingTimeInterval(minutes * 60), end: base.addingTimeInterval((minutes + length) * 60),
                   calendarID: calendar, isAllDay: allDay, currentUserDeclined: declined,
                   attendees: attendees ?? [BriefAttendee(name: "Me", email: nil, isCurrentUser: true), BriefAttendee(name: "Ana López", email: "ana@example.com")],
                   isRecurring: recurring, service: service, invitationNotes: notes)
    }

    static func task(_ id: Int64, _ text: String, owner: Int64? = nil, ownerName: String? = nil, due: Date? = nil, meeting: Int64? = 1, segment: Int64? = nil,
                     status: TaskItem.Status = .open, created: Double = 1_000, unconfirmed: Bool = false) -> TaskItem {
        TaskItem(id: id, meetingID: meeting, segmentID: segment, t: nil, text: text, ownerID: owner, ownerName: ownerName, due: due, status: status,
                 source: "llm", createdAt: Date(timeIntervalSince1970: created), meetingTitle: nil, unconfirmed: unconfirmed)
    }

    static func decision(_ id: Int64, _ text: String, meeting: Int64 = 1, segment: Int64? = nil, unconfirmed: Bool = false) -> Decision {
        Decision(id: id, meetingID: meeting, segmentID: segment, t: nil, text: text, source: "llm", unconfirmed: unconfirmed)
    }

    static func last(id: Int64 = 1, title: String = "Supplier review", summary: String? = "The team compared two suppliers. A third was dropped.",
                     decisions: [Decision] = [], tasks: [TaskItem] = [], questions: [BriefOpenQuestion] = [], topics: [String] = ["supplier change", "shell material"],
                     materials: [BriefMaterial] = [], locale: String? = "en-US") -> BriefLastMeeting {
        BriefLastMeeting(meetingID: id, date: now.addingTimeInterval(-7 * 86_400), title: title, locale: locale, summary: summary, topics: topics,
                         decisions: decisions, openTasks: tasks, openQuestions: questions, materials: materials)
    }

    static func assembly(_ event: BriefEvent = event(), facts: BriefFacts = BriefFacts(), mode: BriefRankingMode = .keyword,
                         query: String = "supplier change shell material budget", sufficient: Bool = true) -> BriefAssembly {
        BriefAssembly(event: event, facts: facts, query: query, querySufficient: sufficient, mode: mode, now: now, locale: "en-US")
    }
}

/// Retrieval from a script. Counts the calls, so a test can say that nothing was asked.
final class FakeRetriever: BriefRetriever, @unchecked Sendable {
    private let lock = NSLock()
    var rankingMode = BriefRankingMode.semantic
    var meetingHits: [BriefMeetingHit] = []
    var documentHits: [BriefDocumentHit] = []
    var cosineValues: [String: Double] = [:]
    var cosinesAvailable = true
    private var _calls: [String] = []
    private var _modes: [BriefRankingMode] = []

    var calls: [String] { lock.withLock { _calls } }
    var requestedModes: [BriefRankingMode] { lock.withLock { _modes } }

    func mode() async -> BriefRankingMode {
        lock.withLock { _calls.append("mode") }
        return rankingMode
    }

    func meetings(for query: String, excluding: Set<Int64>, limit: Int, mode: BriefRankingMode) async -> [BriefMeetingHit] {
        lock.withLock { _calls.append("meetings"); _modes.append(mode) }
        return meetingHits.filter { !excluding.contains($0.meetingID) }
    }

    func documents(for query: String, limit: Int, mode: BriefRankingMode) async -> [BriefDocumentHit] {
        lock.withLock { _calls.append("documents"); _modes.append(mode) }
        return documentHits
    }

    func cosines(query: String, texts: [String]) async -> [Double]? {
        lock.withLock { _calls.append("cosines") }
        guard cosinesAvailable else { return nil }
        return texts.map { cosineValues[$0] ?? 0.1 }
    }
}

struct FakeReminders: BriefReminderSource {
    var accessValue = BriefReminderAccess.granted
    var reminders: [BriefReminder] = []
    var access: BriefReminderAccess { get async { accessValue } }
    func lists() async -> [BriefReminderList] { [] }
    func incompleteReminders(in listIDs: Set<String>, limit: Int) async -> [BriefReminder] { Array(reminders.prefix(limit)) }
}

/// Writes the agenda from a script.
final class FakeWriter: BriefAgendaWriter, @unchecked Sendable {
    private let lock = NSLock()
    var reply: String
    var error: Error?
    var delay: Double = 0
    private var _prompts: [String] = []

    init(reply: String = "{}") { self.reply = reply }

    var prompts: [String] { lock.withLock { _prompts } }
    var callCount: Int { prompts.count }

    func write(_ messages: [ChatMessage], schema: OutputSchema, maxTokens: Int, backend: BriefBackend) async throws -> String {
        lock.withLock { _prompts.append(messages.map(\.content).joined(separator: "\n")) }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if let error { throw error }
        return reply
    }
}
