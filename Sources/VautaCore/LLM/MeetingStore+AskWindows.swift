// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// Ask on the small window (`AskHarness.windows`): short windows of the transcript centred on the lines the keyword search found,
    /// instead of the chunks of about a hundred seconds. A window is the lines from `before` seconds ahead of a hit to `after` seconds
    /// behind it, cut to `maxCharacters`. Its score is the rank of the hits it holds, raised by the share of the question's ideas
    /// (a word, or the other spellings of a number) that appear in it. The best `count` windows that do not overlap are returned,
    /// within `maxChars` of text. Keywords only: a corpus that ranks by meaning keeps the chunks.
    func retrieveWindows(_ question: String, scope: [Int64]?, excluding: Int64?, locale: Locale?, maxChars: Int, windows: AskWindows) throws -> [RetrievedPassage] {
        let profile = locale.map(LanguageProfile.init(locale:)) ?? LanguageProfile.detecting(question)
        let terms = Self.queryTerms(question, profile: profile)
        let groups = AskHarness.termGroups(terms)
        var seenWords = Set<String>()
        let words = groups.flatMap { $0 }.filter { seenWords.insert($0).inserted }
        let spaced = words.filter { !$0.contains(where: TextKeys.isNoSpaceScript) }
        let unspaced = words.filter { $0.contains(where: TextKeys.isNoSpaceScript) }

        // Every hit with its weight: the rank in the keyword search, and the moments the user flagged (1.5 times).
        var hits: [(meeting: Int64, t: Double, weight: Double)] = []
        if !spaced.isEmpty {
            let match = spaced.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " OR ")
            let rows = try db.query("""
                SELECT s.meeting_id, s.start FROM segments_fts f JOIN segments s ON s.id = f.rowid
                WHERE segments_fts MATCH ?1 AND (?2 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?2))) AND (?3 IS NULL OR s.meeting_id <> ?3) AND \(Self.notEcho) ORDER BY rank LIMIT 80
                """, [.text(match), scope.map { .ids($0) }, excluding.map { .integer($0) }])
            for (rank, row) in rows.enumerated() { hits.append((row.int(0), row.double(1), 1 / Double(60 + rank))) }
        }
        if !unspaced.isEmpty {
            let rows = try db.query("""
                SELECT meeting_id, start FROM (
                    SELECT s.meeting_id, s.start, (SELECT COUNT(*) FROM json_each(?1) WHERE instr(s.text, value) > 0) AS found
                    FROM segments s WHERE (?2 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?2))) AND (?3 IS NULL OR s.meeting_id <> ?3) AND \(Self.notEcho))
                WHERE found > 0 ORDER BY found DESC, start LIMIT 80
                """, [.text(Self.json(strings: unspaced)), scope.map { .ids($0) }, excluding.map { .integer($0) }])
            for (rank, row) in rows.enumerated() { hits.append((row.int(0), row.double(1), 1 / Double(60 + rank))) }
        }
        for (rank, moment) in try noteCitedMoments(terms: terms, scope: scope).prefix(40).enumerated() where moment.meeting != excluding {
            hits.append((moment.meeting, moment.t, 1.5 / Double(60 + rank)))
        }
        for (rank, moment) in try itemCitedMoments(terms: terms, scope: scope).enumerated() where moment.meeting != excluding {
            hits.append((moment.meeting, moment.t, itemKeyWeight / Double(60 + rank)))
        }
        // Where the transcript misheard a person or project of the question (`misheardMoments`): as a keyword hit, at half the
        // weight while the correction is open.
        let entities = try entitiesNamed(in: question, locale: profile.locale)
        for (rank, m) in try misheardMoments(of: entities, scope: scope, excluding: excluding).enumerated() {
            hits.append((m.meeting, m.t, (m.confirmed ? 1 : 0.5) / Double(60 + rank)))
        }
        guard !hits.isEmpty else { return [] }

        var ranges: [String: (meeting: Int64, start: Double, end: Double)] = [:]
        var scores: [(key: String, value: Double)] = []
        var seen = Set<String>()
        for hit in hits.sorted(by: { $0.weight > $1.weight }).prefix(windows.candidates) {
            let key = "w\(hit.meeting)@\(Int(hit.t))"
            guard seen.insert(key).inserted else { continue }
            var lines = try db.query("""
                SELECT s.id, s.speaker, s.start, s.text, \(Self.speakerColumns) FROM segments s \(Self.speakerJoins)
                WHERE s.meeting_id = ? AND s.start >= ? AND s.start <= ? AND \(Self.notEcho) ORDER BY s.start, s.id
                """, [.integer(hit.meeting), .real(hit.t - windows.before), .real(hit.t + windows.after)]).map(Self.citable)
            guard !lines.isEmpty else { continue }
            // Cut to the budget: the line furthest from the hit goes first.
            func size(_ l: [CitableSegment]) -> Int { l.reduce(0) { $0 + $1.text.count + 24 } }
            while lines.count > 1, size(lines) > windows.maxCharacters {
                let first = abs(lines[0].start - hit.t), last = abs(lines[lines.count - 1].start - hit.t)
                if first >= last { lines.removeFirst() } else { lines.removeLast() }
            }
            let start = lines[0].start, end = lines[lines.count - 1].start
            // Hits inside the window (each counted once, the same moment found by two searches twice: they are two votes).
            let inside = hits.filter { $0.meeting == hit.meeting && $0.t >= start && $0.t <= end }.reduce(0) { $0 + $1.weight }
            let coverage = Self.coverage(of: groups, in: lines.map(\.text).joined(separator: " "), profile: profile)
            var score = windows.score(hits: inside, coverage: coverage)
            if !entities.isEmpty {
                let named = try db.query("SELECT COUNT(DISTINCT entity_id) FROM mentions WHERE meeting_id = ? AND t BETWEEN ? AND ? AND entity_id IN (SELECT value FROM json_each(?))",
                                         [.integer(hit.meeting), .real(start), .real(end), .ids(entities)])[0].int(0)
                score += Double(named) / 60
            }
            ranges[key] = (hit.meeting, start, end)
            scores.append((key, score))
        }
        return try assemble(scores, ranges: ranges, limit: windows.count, maxChars: maxChars)
    }

    /// The share of `groups` (a word with the other spellings of a number) that appear in `text`; a word appears when a token of the text
    /// starts with it (the search matches by prefix), or, in a script without spaces, contains it.
    static func coverage(of groups: [[String]], in text: String, profile: LanguageProfile) -> Double {
        guard !groups.isEmpty else { return 0 }
        let tokens = TextKeys.tokens(text, profile: profile).map(\.norm)
        let flat = TextKeys.norm(text)
        let held = groups.filter { group in
            group.contains { word in
                let key = TextKeys.norm(word)
                if key.contains(where: { $0.unicodeScalars.contains(where: TextKeys.isNoSpaceScript) }) { return flat.contains(key) }
                return tokens.contains { $0.hasPrefix(key) }
            }
        }
        return Double(held.count) / Double(groups.count)
    }
}
