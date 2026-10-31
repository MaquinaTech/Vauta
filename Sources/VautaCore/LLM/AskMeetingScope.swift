// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where a question across the library looks, from what it names: the meetings of a place ("the last meeting", `AskMeetingPlace`),
/// else those of a time ("last week", `AskTimeScope`), else all of them. Ask, the answers to questions heard in a meeting and
/// `llm-eval` resolve it the same way (`MeetingStore.askScope`), so what is measured is what runs.
public struct AskMeetingScope: Sendable, Equatable {
    /// One meeting, read whole: the place names one.
    public var within: Int64?
    /// Only these meetings: a place that names several, or the meetings of the time. Nil: all of them.
    public var meetings: [Int64]?
    /// The place decided it (else the time did, or nothing).
    public var placed: Bool
    /// The time names no meetings (a day off, a week before the first recording): all of them are searched, and the answer says so.
    public var noMeetingsInPeriod: Bool

    public init(within: Int64? = nil, meetings: [Int64]? = nil, placed: Bool = false, noMeetingsInPeriod: Bool = false) {
        self.within = within
        self.meetings = meetings
        self.placed = placed
        self.noMeetingsInPeriod = noMeetingsInPeriod
    }

    /// All the meetings.
    public static let everywhere = AskMeetingScope()

    /// It narrows the search: to one meeting or to some.
    public var narrows: Bool { within != nil || meetings != nil }

    /// "place:1", "time:3", "none" (no time had meetings) or "" (all): for the evaluation's traces.
    public var trace: String {
        if noMeetingsInPeriod { return "none" }
        let count = within != nil ? 1 : meetings?.count ?? 0
        return narrows ? "\(placed ? "place" : "time"):\(count)" : ""
    }
}

extension MeetingStore {
    /// The meetings `place` names, newest first, within `period` and without `excluding`; nil when it needs a person or project
    /// (`ofNamed`) and `question` names none Vauta knows.
    public func meetingIDs(named place: AskMeetingPlace, in question: String, period: AskTimeScope?, excluding: Int64? = nil) throws -> [Int64]? {
        var entities: [Int64] = []
        if place.ofNamed {
            entities = try entitiesNamed(in: question)
            guard !entities.isEmpty else { return nil }
        }
        return try meetingIDs(at: place.which, entities: entities, from: period?.interval.start, to: period?.interval.end, excluding: excluding)
    }

    /// Where `question` looks with the time and the place given (those the person left on): the place's meetings within the time,
    /// else the time's meetings. `excluding`: never that meeting (the one being recorded, for a question heard in it).
    public func askScope(_ question: String, period: AskTimeScope?, place: AskMeetingPlace?, excluding: Int64? = nil) throws -> AskMeetingScope {
        if let place, let found = try meetingIDs(named: place, in: question, period: period, excluding: excluding), !found.isEmpty {
            return found.count == 1 ? AskMeetingScope(within: found[0], placed: true) : AskMeetingScope(meetings: found, placed: true)
        }
        guard let period else { return .everywhere }
        let ids = try meetingIDs(matching: MeetingFilter(from: period.interval.start, to: period.interval.end)).filter { $0 != excluding }
        return ids.isEmpty ? AskMeetingScope(noMeetingsInPeriod: true) : AskMeetingScope(meetings: ids)
    }

    /// The scope of a question nobody can turn on or off (a question heard in a meeting, the evaluation): the place it names, and the
    /// time it names when that applies by itself (`AskTimeScope.applies`; one that Ask would only offer is left out). Read in the
    /// question's language when it can be told, else in `languages`.
    public func askScope(of question: String, languages: [String], now: Date = .now, calendar: Calendar = .current,
                         excluding: Int64? = nil) throws -> AskMeetingScope {
        let read = OutputLanguage.confident(question).map { [$0.identifier] } ?? languages
        let period = AskTimeScope.read(question, languages: read, now: now, calendar: calendar).flatMap { $0.applies ? $0 : nil }
        return try askScope(question, period: period, place: AskMeetingPlace.read(question, languages: read), excluding: excluding)
    }
}
