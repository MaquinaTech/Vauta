// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where Ask's candidate passages lie and what the context graph says about them, a query per list instead of one per candidate.
extension MeetingStore {
    /// A candidate passage: a stored chunk, or the time bucket of a moment where no chunk exists yet.
    struct Located {
        let key: String
        let meeting: Int64
        let start: Double
        let end: Double
        let chunkID: Int64?

        init(chunk: ChunkSpan, meeting: Int64) {
            key = "c\(chunk.id)"
            self.meeting = meeting
            start = chunk.start
            end = chunk.end
            chunkID = chunk.id
        }

        /// The bucket of ~100 s that holds a moment. Its bounds are whole seconds.
        init(bucketOf t: Double, meeting: Int64) {
            let bucket = (t / MeetingStore.chunkTarget).rounded(.down) * MeetingStore.chunkTarget
            key = "m\(meeting)@\(Int(bucket))"
            self.meeting = meeting
            start = bucket
            end = bucket + MeetingStore.chunkMax
            chunkID = nil
        }
    }

    struct ChunkSpan {
        let id: Int64
        let start: Double
        let end: Double
    }

    /// The chunks that hold a moment of a meeting, ordered by start then id (chunks overlap by a segment, so a moment can belong
    /// to two): chunks of `space`, or of any space without one. A note's moments are few (at most 40), so each is a query.
    func chunks(holding t: Double, in meeting: Int64, space: EmbeddingSpace?) throws -> [ChunkSpan] {
        try db.query("""
            SELECT id, start, end FROM chunks WHERE meeting_id = ?1 AND start <= ?2 AND end >= ?2 AND (?3 IS NULL OR (model = ?3 AND dims = ?4))
            ORDER BY start, id
            """, [.integer(meeting), .real(t), space.map { .text($0.model) }, space.map { .integer(Int64($0.dimensions)) }])
            .map { ChunkSpan(id: $0.int(0), start: $0.double(1), end: $0.double(2)) }
    }

    /// Every chunk of `space` that holds a moment, in order; else the moment's time bucket, when the meeting has no chunk there yet.
    func locate(_ t: Double, in meeting: Int64, space: EmbeddingSpace) throws -> [Located] {
        let holding = try chunks(holding: t, in: meeting, space: space)
        return holding.isEmpty ? [Located(bucketOf: t, meeting: meeting)] : holding.map { Located(chunk: $0, meeting: meeting) }
    }

    /// The chunks that hold each segment's start, by segment, ordered by start then id: chunks of `space`, or of any space
    /// without one. The times are compared in SQL, against the stored values.
    func chunksHolding(_ segments: [Int64], space: EmbeddingSpace?) throws -> [Int64: [ChunkSpan]] {
        guard !segments.isEmpty else { return [:] }
        var out: [Int64: [ChunkSpan]] = [:]
        for r in try db.query("""
            SELECT s.id, c.id, c.start, c.end FROM segments s
            JOIN chunks c ON c.meeting_id = s.meeting_id AND c.start <= s.start AND c.end >= s.start
            WHERE s.id IN (SELECT value FROM json_each(?1)) AND (?2 IS NULL OR (c.model = ?2 AND c.dims = ?3)) ORDER BY c.start, c.id
            """, [.ids(segments), space.map { .text($0.model) }, space.map { .integer(Int64($0.dimensions)) }]) {
            out[r.int(0), default: []].append(ChunkSpan(id: r.int(1), start: r.double(2), end: r.double(3)))
        }
        return out
    }

    /// What the context graph says about each candidate passage: how many of `entities` it names, and whether a speaker the
    /// user named as one of them talks in it. Only named speakers count (a calendar suggestion or a guess never does).
    /// Each range reaches SQL without a time in JSON: a chunk by its id (its row holds the range), a bucket by its whole seconds.
    func graphSignals(_ ranges: [String: (meeting: Int64, start: Double, end: Double)], entities: [Int64]) throws -> [String: (named: Int64, said: Bool)] {
        var chunks: [Int64] = []
        var buckets: [String] = []
        for (key, r) in ranges {
            if key.hasPrefix("c"), let id = Int64(key.dropFirst()) { chunks.append(id) }
            // A bucket's key is "m<meeting>@<seconds>": nothing to escape.
            else { buckets.append("[\"\(key)\",\(r.meeting),\(Int64(r.start)),\(Int64(r.end))]") }
        }
        var out: [String: (named: Int64, said: Bool)] = [:]
        for row in try db.query("""
            WITH r(k, meeting, a, b) AS (
                SELECT 'c' || id, meeting_id, start, end FROM chunks WHERE id IN (SELECT value FROM json_each(?1))
                UNION ALL
                SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]'), json_extract(value, '$[3]')
                FROM json_each(?2))
            SELECT k,
                (SELECT COUNT(DISTINCT entity_id) FROM mentions WHERE meeting_id = r.meeting AND t BETWEEN r.a AND r.b
                   AND entity_id IN (SELECT value FROM json_each(?3))),
                EXISTS (SELECT 1 FROM segments s JOIN meeting_speakers sp ON sp.id = s.speaker_id
                        WHERE s.meeting_id = r.meeting AND s.start BETWEEN r.a AND r.b AND sp.source = 'user'
                          AND sp.entity_id IN (SELECT id FROM entities WHERE id IN (SELECT value FROM json_each(?3)) OR merged_into IN (SELECT value FROM json_each(?3)))
                          AND (s.speaker_confidence IS NULL OR s.speaker_confidence >= ?4) AND s.overlap = 0 AND \(Self.notEcho))
            FROM r
            """, [.ids(chunks), .text("[" + buckets.joined(separator: ",") + "]"), .ids(entities), .real(SpeakerTag.lowConfidenceBelow)]) {
            out[row.string(0)] = (row.int(1), row.int(2) != 0)
        }
        return out
    }
}
