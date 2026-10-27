// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What Ask needs of the store when the meeting being recorded is embedded on demand (E3, `LLMService.embedLivePrefix`) and when a
/// question is translated to the language of the transcripts (E4).
extension MeetingStore {
    /// A stored chunk of a meeting, identified by where it starts and by the fingerprint of the text it was embedded from.
    public struct ChunkKey: Sendable, Hashable {
        public let start: Double
        public let key: String
        public init(start: Double, key: String) {
            self.start = start
            self.key = key
        }
    }

    /// The chunks a meeting has in `space`. Chunks of any other space are not listed: the next write removes them.
    public func storedChunkKeys(_ meetingID: Int64, space: EmbeddingSpace) throws -> Set<ChunkKey> {
        Set(try db.query("SELECT start, text_key FROM chunks WHERE meeting_id = ? AND model = ? AND dims = ?",
                         [.integer(meetingID), .text(space.model), .integer(Int64(space.dimensions))])
            .map { ChunkKey(start: $0.double(0), key: $0.string(1)) })
    }

    /// Removes the chunks of a meeting that are not in `keep` (text that changed since it was embedded, or another space).
    @discardableResult
    public func dropChunks(_ meetingID: Int64, keeping keep: Set<ChunkKey>, space: EmbeddingSpace) async throws -> Int {
        let rows = try db.query("SELECT id, start, text_key, model, dims FROM chunks WHERE meeting_id = ?", [.integer(meetingID)])
        let stale = rows.filter { r in
            !(r.string(3) == space.model && Int(r.int(4)) == space.dimensions && keep.contains(ChunkKey(start: r.double(1), key: r.string(2))))
        }.map { $0.int(0) }
        guard !stale.isEmpty else { return 0 }
        try transaction { try run("DELETE FROM chunks WHERE id IN (SELECT value FROM json_each(?))", [.ids(stale)]) }
        vectorCache = nil
        try await commitEdit()
        return stale.count
    }

    /// Adds chunks to a meeting without touching the ones it has (`replaceChunks` replaces them all). A chunk already stored at the
    /// same start with the same text is not written twice.
    public func addChunks(_ meetingID: Int64, _ items: [(start: Double, end: Double, q: Data, scale: Float, key: String)],
                          space: EmbeddingSpace) async throws {
        let have = try storedChunkKeys(meetingID, space: space)
        let new = items.filter { $0.q.count == space.dimensions && !have.contains(ChunkKey(start: $0.start, key: $0.key)) }
        guard !new.isEmpty else { return }
        try transaction {
            for c in new {
                try run("INSERT INTO chunks(meeting_id, start, end, model, dims, scale, emb, text_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        [.integer(meetingID), .real(c.start), .real(c.end), .text(space.model), .integer(Int64(space.dimensions)),
                         .real(Double(c.scale)), .blob(c.q), .text(c.key)])
            }
        }
        vectorCache = nil
        try await commitEdit()
    }

    /// The transcription language every meeting that has lines shares (nil when they differ or there are none). A question in another
    /// language is translated to it only then: with a library in two languages there is no one language to translate to.
    public func singleTranscriptionLanguage() throws -> Locale.Language? {
        let rows = try db.query("""
            SELECT DISTINCT coalesce(locale, ?) FROM meetings WHERE EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
            """, [.text(Meeting.legacyLocaleIdentifier)])
        let codes = Set(rows.compactMap { Locale(identifier: $0.string(0)).language.minimalIdentifier })
        guard codes.count == 1, let only = rows.first else { return nil }
        return Locale(identifier: only.string(0)).language
    }
}
