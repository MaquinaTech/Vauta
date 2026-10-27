// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What Vauta takes from a calendar event for the meeting being recorded.
/// Only what concerns the transcribed meeting is stored (encrypted, in the
/// store); nothing else from the calendar is stored or cached.
public struct CalendarMeeting: Sendable, Equatable {
    public struct Attendee: Sendable, Equatable {
        public let name: String
        /// Stable key to link with people (from `mailto:`).
        public let email: String?
        public let isCurrentUser: Bool
        public init(name: String, email: String?, isCurrentUser: Bool) {
            self.name = name
            self.email = email
            self.isCurrentUser = isCurrentUser
        }
    }

    public let title: String
    public let attendees: [Attendee]
    /// Identifier of the recurring event (nil if it does not repeat).
    public let seriesKey: String?

    public init(title: String, attendees: [Attendee], seriesKey: String?) {
        self.title = title
        self.attendees = attendees
        self.seriesKey = seriesKey
    }
}

/// An attendee and the person the store knows them as (nil: nobody, or not unambiguous).
public struct ResolvedAttendee: Sendable, Equatable {
    public let attendee: CalendarMeeting.Attendee
    public let entityID: Int64?
    public init(attendee: CalendarMeeting.Attendee, entityID: Int64?) {
        self.attendee = attendee
        self.entityID = entityID
    }
}

extension MeetingStore {
    /// Title, attendees and recurring series. Attendees are linked by email;
    /// without one, to the only confirmed person (or earlier pending
    /// calendar person) with the same name; otherwise they become pending
    /// people with their full name and given name as aliases.
    /// Returns the attendees' IDs (suggestions for naming "Others").
    @discardableResult
    public func applyCalendar(_ event: CalendarMeeting, to meetingID: Int64) async throws -> [Int64] {
        let title = Self.clean(event.title, max: 200)
        let attendees: [Int64] = try transaction {
            if !title.isEmpty {
                try run("UPDATE meetings SET title = ? WHERE id = ?", [.text(title), .integer(meetingID)])
            }
            var ids: [Int64] = []
            for a in event.attendees where !a.isCurrentUser {
                let name = Self.clean(a.name, max: 200)
                let email = a.email.map { Self.clean($0, max: 320).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
                guard !name.isEmpty || email != nil else { continue }
                let found = try lookupAttendee(name: name, email: email)
                var id = found?.id
                if let found, found.adoptEmail, let email {
                    try run("UPDATE entities SET email = ? WHERE id = ? AND email IS NULL", [.text(email), .integer(found.id)])
                }
                if id == nil {
                    let shown = name.isEmpty ? (email ?? "") : name
                    try run("""
                        INSERT INTO entities(kind, name, email, source, confirmed, created_at) VALUES ('person', ?, ?, 'calendar', 0, ?)
                        """, [.text(shown), email.map { .text($0) }, .real(Date.now.timeIntervalSince1970)])
                    let new = db.lastInsertRowID
                    let norm = TextKeys.norm(shown)
                    if !norm.isEmpty { try addAlias(shown, norm: norm, to: new, source: "calendar") }
                    // The given name is how people are usually named in the meeting.
                    if !name.isEmpty, let given = Self.givenName(of: name) {
                        try addAlias(given, norm: TextKeys.norm(given), to: new, source: "calendar", weight: 0.75)
                    }
                    id = new
                }
                if let id {
                    try run("INSERT OR IGNORE INTO meeting_entities(meeting_id, entity_id, role) VALUES (?, ?, 'attendee')",
                            [.integer(meetingID), .integer(id)])
                    ids.append(id)
                }
            }
            if let key = event.seriesKey.map({ Self.clean($0, max: 400) }), !key.isEmpty {
                var series = try db.query("SELECT id FROM series WHERE calendar_key = ?", [.text(key)]).first?.int(0)
                if series == nil, !title.isEmpty {
                    try run("INSERT INTO series(calendar_key, title_pattern, default_entities) VALUES (?, ?, ?)",
                            [.text(key), .text(title), .text(Self.json(ids: ids))])
                    series = db.lastInsertRowID
                }
                if let series {
                    try run("UPDATE meetings SET series_id = ? WHERE id = ?", [.integer(series), .integer(meetingID)])
                }
            } else if !title.isEmpty, let match = try seriesMatching(title: title), let sid = match.id {
                try run("UPDATE meetings SET series_id = ? WHERE id = ?", [.integer(sid), .integer(meetingID)])
            }
            return ids
        }
        try await commitEdit()
        return attendees
    }

    /// The person an attendee is: by email, else by the only confirmed (or earlier pending calendar) person with the same full name.
    /// A SELECT only: `applyCalendar` adds what is missing, the brief (before any recording) never does. `adoptEmail` says the match was
    /// by name and the person has no address yet, so a recording may store the attendee's.
    func lookupAttendee(name: String, email: String?) throws -> (id: Int64, adoptEmail: Bool)? {
        if let email, let id = try db.query("SELECT coalesce(merged_into, id) FROM entities WHERE email = ?", [.text(email)]).first?.int(0) {
            return (id, false)
        }
        if !name.isEmpty, let known = try person(named: name, withoutEmailOnly: email != nil) { return (known, true) }
        return nil
    }

    /// Who the attendees are, without writing anything: the same email and unique-name matching `applyCalendar` uses. The current
    /// user is left out. An attendee several people could be, or nobody knows, has no entity.
    public func resolveAttendees(_ attendees: [CalendarMeeting.Attendee]) throws -> [ResolvedAttendee] {
        var out: [ResolvedAttendee] = []
        for a in attendees where !a.isCurrentUser {
            let name = Self.clean(a.name, max: 200)
            let email = a.email.map { Self.clean($0, max: 320).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
            guard !name.isEmpty || email != nil else { continue }
            out.append(ResolvedAttendee(attendee: a, entityID: try lookupAttendee(name: name, email: email)?.id))
        }
        return out
    }

    /// A known person with exactly this full name: the only confirmed one or,
    /// failing that, the only pending calendar person. When the attendee has
    /// an (unknown) email, only people without an email qualify: a different
    /// address means a different person. Never guesses between several.
    private func person(named name: String, withoutEmailOnly: Bool) throws -> Int64? {
        let norm = TextKeys.norm(name)
        guard !norm.isEmpty else { return nil }
        let rows = try db.query("""
            SELECT DISTINCT e.id, e.confirmed, e.email IS NULL FROM aliases a JOIN entities e ON e.id = a.entity_id
            WHERE a.alias_norm = ? AND e.kind = 'person' AND e.merged_into IS NULL AND (e.confirmed = 1 OR e.source = 'calendar')
            """, [.text(norm)]).filter { !withoutEmailOnly || $0.int(2) != 0 }
        let confirmed = rows.filter { $0.int(1) != 0 }
        if !confirmed.isEmpty { return confirmed.count == 1 ? confirmed[0].int(0) : nil }
        return rows.count == 1 ? rows[0].int(0) : nil
    }

    /// The given name to use as a short alias, or nil when there is no safe
    /// one. Handles "Last, First", honorifics ("Dr. John Smith") and
    /// family-name-first order through `PersonNameComponentsFormatter`. Names
    /// in Han, Kana or Hangul get no short alias: people are addressed by
    /// their full name (or family name), and a one- or two-character given
    /// name would match inside unrelated words.
    static func givenName(of fullName: String) -> String? {
        if fullName.contains("@") { return nil }
        if fullName.unicodeScalars.contains(where: { TextKeys.isNoSpaceScript($0) || (0xAC00...0xD7AF).contains($0.value) }) { return nil }
        // Honorifics written with a period ("Dr.", "Prof.", "Sr.") are dropped first.
        var words = fullName.split(separator: " ")
        while words.count > 1, let first = words.first, first.hasSuffix("."), first.count <= 6 { words.removeFirst() }
        let name = words.joined(separator: " ")
        guard let components = PersonNameComponentsFormatter().personNameComponents(from: name),
              let given = (components.givenName ?? components.nickname)?.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)),
              given.count >= 2, TextKeys.norm(given) != TextKeys.norm(fullName), !given.contains(" ")
        else { return nil }
        return given
    }

    public func seriesID(of meetingID: Int64) throws -> Int64? {
        try db.query("SELECT series_id FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.optionalInt(0)
    }

    /// Vocabulary for the transcriber (≤ 100 phrases of 1–2 words, by
    /// priority): attendees, series entities and pinned glossary terms.
    public func recognitionVocabulary(attendees: [Int64], seriesID: Int64? = nil) throws -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let words = s.split(separator: " ")
            guard (1...2).contains(words.count), out.count < TranscriptionEngine.maxVocabulary else { return }
            if seen.insert(TextKeys.norm(s)).inserted { out.append(s) }
        }
        if !attendees.isEmpty {
            for r in try db.query("SELECT alias FROM aliases WHERE entity_id IN (SELECT value FROM json_each(?)) ORDER BY weight DESC", [.ids(attendees)]) { add(r.string(0)) }
        }
        if let seriesID {
            for r in try db.query("""
                SELECT a.alias FROM series s, json_each(s.default_entities) j JOIN aliases a ON a.entity_id = j.value
                WHERE s.id = ? ORDER BY a.weight DESC
                """, [.integer(seriesID)]) { add(r.string(0)) }
        }
        for r in try db.query("SELECT term FROM glossary WHERE pinned = 1 ORDER BY term") { add(r.string(0)) }
        for r in try db.query("""
            SELECT a.alias FROM aliases a JOIN entities e ON e.id = a.entity_id
            WHERE e.kind IN ('project','client','system') AND e.merged_into IS NULL ORDER BY e.last_seen DESC
            """) { add(r.string(0)) }
        return out
    }
}
