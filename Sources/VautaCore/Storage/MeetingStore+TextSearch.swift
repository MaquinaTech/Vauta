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

    /// An excerpt of `text` around its first match of `words` (case- and diacritic-insensitive), with every match
    /// between the markers, for searches that do not go through the FTS index.
    static func snippet(_ text: String, marking words: [String], before: Int = 24, after: Int = 64) -> String {
        var found: [Range<String.Index>] = []
        for word in words where !word.isEmpty {
            var from = text.startIndex
            while let r = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                found.append(r)
                from = r.upperBound
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        let first = found.first ?? text.startIndex..<text.startIndex
        let lower = text.index(first.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(first.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        var out = lower > text.startIndex ? ellipsis : ""
        var at = lower
        for r in found where r.lowerBound >= at && r.upperBound <= upper {
            out += text[at..<r.lowerBound]
            out += start + text[r] + end
            at = r.upperBound
        }
        out += text[at..<upper]
        return upper < text.endIndex ? out + ellipsis : out
    }
}

/// The words of a search box query. One-letter words are ignored when there are longer ones (a one-letter prefix
/// scans half the index). The FTS indexes (unicode61) keep a run of Han, Kana or Thai text as one token, so a word
/// in the middle of such a sentence never matches by prefix: a query with a word of those scripts is matched by
/// substring instead, every word of it (a Latin name is often written inside the run, as in "和Kobaltix的").
struct SearchWords {
    let words: [String]

    init?(_ text: String) {
        var words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.contains(where: { $0.count > 1 }) { words.removeAll { $0.count < 2 } }
        guard !words.isEmpty else { return nil }
        self.words = words
    }

    var bySubstring: Bool { words.contains { $0.contains(where: TextKeys.isNoSpaceScript) } }
    /// The FTS5 query: every word quoted and by prefix, so input is never parsed as FTS5 syntax.
    var match: String { words.map { "\"\($0)\"*" }.joined(separator: " ") }
    /// The words as JSON, for `json_each`.
    var json: String { MeetingStore.json(strings: words) }

    /// SQL that is true when `column` contains every word (`?N` binds `json`). `lower` folds ASCII on both sides.
    static func containsAll(_ column: String, param: Int) -> String {
        "NOT EXISTS (SELECT 1 FROM json_each(?\(param)) WHERE instr(lower(\(column)), lower(value)) = 0)"
    }
}

extension MeetingStore {
    /// Full-text search (case- and diacritic-insensitive, by prefix; see `SearchWords`), best matches first, or the
    /// newest meetings first when the query is matched by substring.
    /// `meetings`: limits the search to those meetings (filters by person, project…).
    public func search(_ text: String, in meetings: [Int64]? = nil, limit: Int = 50) throws -> [SearchHit] {
        guard let query = SearchWords(text) else { return [] }
        let substring = query.bySubstring
        return try db.query("""
            SELECT m.id, m.started_at, m.ended_at, m.title,
                   s.id, s.meeting_id, s.speaker, s.start, s.end, s.text,
                   \(substring ? "''" : SearchHighlight.snippetSQL("segments_fts")),
                   m.locale, m.output_locale, m.source_app, \(Self.speakerColumns)
            FROM \(substring ? "segments s" : "segments_fts f JOIN segments s ON s.id = f.rowid")
            JOIN meetings m ON m.id = s.meeting_id
            \(Self.speakerJoins)
            WHERE \(substring ? SearchWords.containsAll("s.text", param: 1) : "segments_fts MATCH ?1")
              AND (?3 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?4))) AND \(Self.notEcho)
            ORDER BY \(substring ? "m.started_at DESC, s.start" : "rank") LIMIT ?2
            """, [.text(substring ? query.json : query.match), .integer(Int64(limit)),
                  meetings == nil ? nil : .integer(1), .ids(meetings ?? [])]).map { row in
            SearchHit(meeting: Self.meeting(row, languageAt: 11),
                      segment: StoredSegment(id: row.int(4), meetingID: row.int(5), channel: Channel(storedSpeaker: row.string(6)),
                                             start: row.double(7), end: row.double(8), text: row.string(9),
                                             speaker: Self.speakerTag(row, at: 14)),
                      snippet: substring ? SearchHighlight.snippet(row.string(9), marking: query.words) : row.string(10))
        }
    }
}
