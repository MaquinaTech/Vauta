// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Markers around the matches in search snippets (transcript and knowledge
/// search). Private-use code points never appear in transcripts, unlike
/// quotation marks such as « » used in French, Spanish or Russian text.
public enum SearchHighlight {
    public static let start = "\u{E000}"
    public static let end = "\u{E001}"
    /// Shown where a snippet cuts the text.
    public static let ellipsis = "…"

    /// The `snippet()` arguments for an FTS5 table's first column, with these markers.
    static func snippetSQL(_ table: String, tokens: Int = 16) -> String {
        "snippet(\(table), 0, '\(start)', '\(end)', '\(ellipsis)', \(tokens))"
    }

    /// A snippet split into plain and matched runs, without the markers, for
    /// display. An unterminated match runs to the end of the snippet.
    public static func runs(in snippet: String) -> [(text: String, isMatch: Bool)] {
        var out: [(text: String, isMatch: Bool)] = []
        var rest = Substring(snippet)
        while !rest.isEmpty {
            guard let open = rest.range(of: start) else {
                out.append((String(rest), false))
                break
            }
            if open.lowerBound > rest.startIndex { out.append((String(rest[..<open.lowerBound]), false)) }
            rest = rest[open.upperBound...]
            let close = rest.range(of: end)
            let match = rest[..<(close?.lowerBound ?? rest.endIndex)]
            if !match.isEmpty { out.append((String(match), true)) }
            rest = close.map { rest[$0.upperBound...] } ?? ""
        }
        return out
    }
}

extension MeetingStore {
    /// Full-text search (case- and diacritic-insensitive, by prefix). The
    /// user's query is reduced to quoted words: it is never interpreted as
    /// FTS5 syntax. One-letter words are ignored when there are longer ones (a
    /// one-letter prefix scans half the index).
    /// `meetings`: limits the search to those meetings (filters by person, project…).
    public func search(_ text: String, in meetings: [Int64]? = nil, limit: Int = 50) throws -> [SearchHit] {
        var words = text.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.count > 1 }) { words.removeAll { $0.count < 2 } }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        return try db.query("""
            SELECT m.id, m.started_at, m.ended_at, m.title,
                   s.id, s.meeting_id, s.speaker, s.start, s.end, s.text,
                   \(SearchHighlight.snippetSQL("segments_fts")),
                   m.locale, m.output_locale, m.source_app, \(Self.speakerColumns)
            FROM segments_fts f
            JOIN segments s ON s.id = f.rowid
            JOIN meetings m ON m.id = s.meeting_id
            \(Self.speakerJoins)
            WHERE segments_fts MATCH ?1 AND (?3 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?4)))
            ORDER BY rank LIMIT ?2
            """, [.text(match), .integer(Int64(limit)), meetings == nil ? nil : .integer(1), .ids(meetings ?? [])]).map { row in
            SearchHit(meeting: Self.meeting(row, languageAt: 11),
                      segment: StoredSegment(id: row.int(4), meetingID: row.int(5), channel: Channel(storedSpeaker: row.string(6)),
                                             start: row.double(7), end: row.double(8), text: row.string(9),
                                             speaker: Self.speakerTag(row, at: 14)),
                      snippet: row.string(10))
        }
    }
}
