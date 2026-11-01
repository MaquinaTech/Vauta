// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Translated transcripts (Meetings → Transcript → Translate, `TranscriptTranslator`): the lines of a finished meeting to read
/// in another language, and their translations, each stored with the text it was made from.
extension MeetingStore {
    /// A line of a transcript to read in another language.
    public struct TranslationLine: Sendable, Equatable {
        public let segmentID: Int64
        public let text: String
        /// Its translation of `text` into the language asked for, if it has one.
        public var translation: String?
        /// It has a translation into that language of an earlier text: it was corrected since.
        public var stale: Bool

        public init(segmentID: Int64, text: String, translation: String? = nil, stale: Bool = false) {
            self.segmentID = segmentID
            self.text = text
            self.translation = translation
            self.stale = stale
        }
    }

    /// A translation to store: `text` translates `source`, what line `segmentID` read when it was translated.
    public struct LineTranslation: Sendable, Equatable {
        public let segmentID: Int64
        public let source: String
        public let text: String

        public init(segmentID: Int64, source: String, text: String) {
            self.segmentID = segmentID
            self.source = source
            self.text = text
        }
    }

    /// The lines of finished meeting `meetingID` to read in `language` (a `storageCode`), in transcript order: every line with
    /// words except the echoes, each with its translation into `language` when it has one of what it reads now (one that reads the
    /// same, for a line already in that language, counts), or marked `stale` when its translation is of an earlier text.
    public func translationLines(of meetingID: Int64, language: String) throws -> [TranslationLine] {
        guard meetingID != activeMeetingID else { throw StoreError(.meetingInProgress) }
        return try db.query("""
            SELECT s.id, s.text, t.text, coalesce(\(Self.translationIsCurrent), 0) FROM segments s
            LEFT JOIN segment_translations t ON t.segment_id = s.id AND t.lang = ?
            WHERE s.meeting_id = ? AND \(Self.notEcho) AND trim(s.text) <> ''
            ORDER BY s.start, s.id
            """, [.text(language), .integer(meetingID)]).map { row in
            let stored = row.optionalString(2)
            let current = stored != nil && row.int(3) == 1
            return TranslationLine(segmentID: row.int(0), text: row.string(1), translation: current ? stored : nil,
                                   stale: stored != nil && !current)
        }
    }

    /// Stores translations of lines of `meetingID` into `language`, replacing what each line had in that language. Each is stored
    /// only while its line still reads its `source`: a line corrected, split or deleted meanwhile keeps what it has. Returns how
    /// many were stored.
    @discardableResult
    public func saveLineTranslations(_ items: [LineTranslation], language: String, inMeeting meetingID: Int64) async throws -> Int {
        guard meetingID != activeMeetingID else { throw StoreError(.meetingInProgress) }
        var stored = 0
        try transaction {
            for item in items where !item.text.isEmpty {
                try run("""
                    INSERT OR REPLACE INTO segment_translations(segment_id, lang, text, source)
                    SELECT id, ?, ?, text FROM segments WHERE id = ? AND meeting_id = ? AND text = ?
                    """, [.text(language), .text(item.text), .integer(item.segmentID), .integer(meetingID), .text(item.source)])
                stored += db.changes
            }
        }
        if stored > 0 { try await commitEdit() }
        return stored
    }
}
