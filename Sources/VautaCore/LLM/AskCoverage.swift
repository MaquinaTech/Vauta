// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What an answer of Ask over the library looked at, for the line under it: the meetings whose transcripts were searched and their
/// dates, the meetings and documents whose passages reached the model, and the meetings of the scope that could not be searched like
/// the rest (their transcript was deleted after `MeetingStore.retentionDays`, or they have no vectors where the search ranks by meaning).
public struct AskCoverage: Sendable, Equatable {
    /// Meetings of the scope (the library, or the meetings of the time the question names) with a transcript: the ones searched.
    public var searched: Int
    /// When the first and the last of them started.
    public var first: Date?, last: Date?
    /// Meetings of the scope whose transcript retention deleted: their minutes stay, but Ask searches transcripts.
    public var purged: Int
    /// Searched meetings without vectors in the space that ranks by meaning, so found by keywords alone (0 when the search is by keywords).
    public var keywordsOnly: Int
    /// Meetings whose passages were sent to the model.
    public var sentMeetings: Int
    /// Documents whose passages were sent to the model.
    public var sentDocuments: Int

    public init(searched: Int, first: Date? = nil, last: Date? = nil, purged: Int = 0, keywordsOnly: Int = 0, sentMeetings: Int = 0,
                sentDocuments: Int = 0) {
        self.searched = searched
        self.first = first
        self.last = last
        self.purged = purged
        self.keywordsOnly = keywordsOnly
        self.sentMeetings = sentMeetings
        self.sentDocuments = sentDocuments
    }

    /// The days of the meetings searched as the person reads them: "Oct 28, 2026", "Aug 3 – Oct 29, 2026".
    public func days(calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let first, let last else { return nil }
        if calendar.isDate(first, inSameDayAs: last) {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("yMMMd")
            return formatter.string(from: first)
        }
        let range = DateIntervalFormatter()
        range.calendar = calendar
        range.timeZone = calendar.timeZone
        range.locale = locale
        range.dateTemplate = "yMMMd"
        return range.string(from: first, to: last)
    }
}

extension MeetingStore {
    /// The scope's part of `AskCoverage` (`sentMeetings` and `sentDocuments` are 0). `meetings` nil is the whole library; `space` is the
    /// one that ranks by meaning (nil when the search is by keywords). Counted as `retrieve` searches: a meeting with segments.
    public func askCoverage(meetings: [Int64]?, space: EmbeddingSpace?) throws -> AskCoverage {
        let scope: SQLiteValue? = meetings.map { .ids($0) }
        let row = try db.query("""
            SELECT COUNT(*), MIN(started_at), MAX(started_at) FROM meetings
            WHERE (?1 IS NULL OR id IN (SELECT value FROM json_each(?1)))
              AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
            """, [scope])[0]
        let purged = try db.query("""
            SELECT COUNT(*) FROM meetings WHERE raw_purged_at IS NOT NULL AND (?1 IS NULL OR id IN (SELECT value FROM json_each(?1)))
            """, [scope])[0].int(0)
        var keywordsOnly: Int64 = 0
        if let space {
            // Covered as `vectorCoverage` counts it: every chunk of the meeting is in the space.
            keywordsOnly = try db.query("""
                SELECT COUNT(*) FROM meetings
                WHERE (?1 IS NULL OR id IN (SELECT value FROM json_each(?1)))
                  AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
                  AND NOT (EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = meetings.id AND c.model = ?2 AND c.dims = ?3)
                           AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = meetings.id AND (c.model <> ?2 OR c.dims <> ?3)))
                """, [scope, .text(space.model), .integer(Int64(space.dimensions))])[0].int(0)
        }
        return AskCoverage(searched: Int(row.int(0)), first: row.optionalDouble(1).map(Date.init(timeIntervalSince1970:)),
                           last: row.optionalDouble(2).map(Date.init(timeIntervalSince1970:)), purged: Int(purged), keywordsOnly: Int(keywordsOnly))
    }
}

extension LLMService {
    /// The line under an answer over the library: the scope that was searched, and what of it reached the model (`documents`: how many
    /// documents had passages sent).
    func askCoverage(meetings: [Int64]?, space: EmbeddingSpace?, passages: [RetrievedPassage], documents: Int) async -> AskCoverage? {
        guard var coverage = try? await store.askCoverage(meetings: meetings, space: space) else { return nil }
        coverage.sentMeetings = Set(passages.map(\.meeting.id)).count
        coverage.sentDocuments = documents
        return coverage
    }
}
