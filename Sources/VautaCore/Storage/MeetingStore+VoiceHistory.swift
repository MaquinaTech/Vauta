// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// One earlier meeting where a speaker's voice resembles a saved voice. Describes the meeting, never the voice.
public struct PastVoiceMatch: Sendable, Identifiable, Hashable {
    public var id: Int64 { speakerID }
    public let speakerID: Int64
    public let meetingID: Int64
    public let meetingTitle: String?
    public let meetingDate: Date
    /// The speaker's number in that meeting ("Speaker 2"), so the user can find them there.
    public let speakerOrdinal: Int
    /// How long that speaker talks in the meeting, in seconds.
    public let talkSeconds: Double
    /// One of the speaker's lines (the transcript text the user already has), shown so the match can be judged.
    public let excerpt: String?

    public init(speakerID: Int64, meetingID: Int64, meetingTitle: String?, meetingDate: Date,
                speakerOrdinal: Int = 1, talkSeconds: Double = 0, excerpt: String? = nil) {
        self.speakerID = speakerID
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.speakerOrdinal = speakerOrdinal
        self.talkSeconds = talkSeconds
        self.excerpt = excerpt
    }
}

/// The result of looking for a saved voice in earlier meetings: where it was found, and what undoes the suggestions it wrote.
/// Holds no voice data.
public struct PastVoiceSweep: Sendable {
    public let entityID: Int64
    public let matches: [PastVoiceMatch]
    /// Puts every speaker the sweep touched back as it was (`MeetingStore.undo`).
    public let undo: SpeakerUndo

    public var isEmpty: Bool { matches.isEmpty }
}

/// Finding a voice the user just confirmed in EARLIER meetings. The user asks for it (the app offers it after "Is this
/// Ana?" is accepted or a voice is saved, and never runs it by itself); the matching runs here on the lasting centroids
/// of `MeetingStore+VoiceRecognition.swift`; a find is only a suggestion ("Is this Ana?", source `suggested`), never a
/// name: the user accepts or rejects it meeting by meeting with `assignSpeaker` and `rejectSuggestion`.
extension MeetingStore {
    /// Looks for `entityID`'s saved voice among the speakers of earlier meetings and offers the person as a suggestion
    /// for each speaker that resembles it (cosine at or above `VoiceProfileThresholds.suggest`).
    ///
    /// - `recognizing`: "Recognize voices across meetings" is on. Off: nothing is read or written.
    /// - `excludingMeeting`: the meeting where the user just answered.
    /// - Never touches: a speaker the user named or unnamed, a speaker already suggested as somebody else, a person the
    ///   user rejected for that meeting, a person the user gave to another speaker of that meeting, the user's own voice in
    ///   a live recording (the user is the Me channel), a meeting without speakers, a centroid of another embedding model.
    ///   When a speaker resembles two saved people, the closer one wins, as at finalization.
    /// - Only centroids younger than `VoiceProfileThresholds.keptSummaryDays` are searched, whether or not the purge has run.
    /// - A meeting never ends up with two suggestions of the same person: a new find replaces the older one, and a find on
    ///   the speaker already suggested as this person changes nothing and is not reported.
    public func suggestVoiceInPastMeetings(of entityID: Int64, excludingMeeting: Int64? = nil, recognizing: Bool, now: Date = .now) async throws -> PastVoiceSweep {
        guard recognizing else { return PastVoiceSweep(entityID: entityID, matches: [], undo: SpeakerUndo()) }
        let model = DiarizationModels.embeddingModelID
        var found: [PastVoiceMatch] = []
        var undo = SpeakerUndo()
        var live = entityID
        let cutoff = now.timeIntervalSince1970 - Double(VoiceProfileThresholds.keptSummaryDays) * 86_400
        try transaction {
            guard let person = try db.query("SELECT coalesce(merged_into, id) FROM entities WHERE id = ? AND kind = 'person'",
                                            [.integer(entityID)]).first?.int(0) else { throw KnowledgeError.entityGone }
            live = person
            let profiles = try voiceProfileEmbeddings(modelID: model)
            guard profiles.contains(where: { $0.entityID == person }) else { return }
            let own = try selfEntityID()
            // The centroid; the short-lived summary serves meetings kept before centroids existed. Everything the loop needs
            // is read here and in two more queries (rejections, named people), never one query per meeting.
            let rows = try db.query("""
                SELECT s.id, s.meeting_id, s.entity_id, s.source, coalesce(c.model_id, v.model_id), coalesce(c.embedding, v.embedding),
                       m.title, m.started_at, m.imported, coalesce(e.merged_into, e.id), s.ordinal, s.talk_seconds
                FROM meeting_speakers s
                JOIN meetings m ON m.id = s.meeting_id
                LEFT JOIN speaker_centroids c ON c.speaker_id = s.id
                LEFT JOIN speaker_voices v ON v.speaker_id = s.id
                LEFT JOIN entities e ON e.id = s.entity_id
                WHERE s.channel = 'others' AND m.speakers_off = 0 AND s.source <> 'user' AND m.id IS NOT ?1
                  AND coalesce(c.speaker_id, v.speaker_id) IS NOT NULL
                  AND coalesce(c.created_at, v.created_at) >= ?2
                ORDER BY s.meeting_id, s.ordinal
                """, [excludingMeeting.map { .integer($0) }, .real(cutoff)])
            var byMeeting: [Int64: [Row]] = [:]
            var order: [Int64] = []
            for row in rows where row.string(4) == model {
                let meeting = row.int(1)
                if byMeeting[meeting] == nil { order.append(meeting) }
                byMeeting[meeting, default: []].append(row)
            }
            var rejected: [Int64: Set<Int64>] = [:]
            for row in try db.query("SELECT meeting_id, entity_id FROM speaker_suggestion_rejections") { rejected[row.int(0), default: []].insert(row.int(1)) }
            var named: [Int64: Set<Int64>] = [:]
            for row in try db.query("""
                SELECT s.meeting_id, coalesce(e.merged_into, s.entity_id) FROM meeting_speakers s LEFT JOIN entities e ON e.id = s.entity_id
                WHERE s.source = 'user' AND s.entity_id IS NOT NULL AND s.channel = 'others'
                """) { named[row.int(0), default: []].insert(row.int(1)) }
            var hits: [Row] = []
            for meeting in order {
                let speakerRows = byMeeting[meeting]!
                var excluded = rejected[meeting] ?? []
                excluded.formUnion(named[meeting] ?? [])
                if speakerRows[0].int(8) == 0, let own { excluded.insert(own) }
                // A person the user rejected under a name that was merged since is still rejected.
                guard !excluded.contains(person) else { continue }
                // A speaker already suggested as another person is left alone; the rest compete for the voice.
                let candidates = speakerRows.filter { row in
                    guard row.optionalInt(2) != nil, row.string(3) == MeetingSpeaker.Source.suggested.rawValue else { return true }
                    return row.optionalInt(9) == person
                }
                let vectors = candidates.compactMap { row in VoiceMatcher.decode(row.data(5)).map { (speaker: Int(row.int(0)), vector: $0) } }
                let templates = VoiceMatcher.templates(from: profiles, excluding: excluded)
                guard let hit = VoiceMatcher.match(vectors: vectors, against: templates).first(where: { $0.entityID == person }),
                      let row = candidates.first(where: { Int($0.int(0)) == hit.speaker }) else { continue }
                // Already suggested as this person: nothing to write, nothing to report.
                if row.string(3) == MeetingSpeaker.Source.suggested.rawValue, row.optionalInt(9) == person { continue }
                hits.append(row)
            }
            let changed = hits.map { $0.int(0) }
            // Another speaker of the same meeting already suggested as this person gives way to the new find.
            let cleared = try db.query("""
                SELECT s.id FROM meeting_speakers s
                WHERE s.meeting_id IN (SELECT value FROM json_each(?1)) AND s.source = 'suggested' AND s.entity_id IS NOT NULL
                  AND coalesce((SELECT merged_into FROM entities WHERE id = s.entity_id), s.entity_id) = ?2
                  AND s.id NOT IN (SELECT value FROM json_each(?3))
                """, [.ids(hits.map { $0.int(1) }), .integer(person), .ids(changed)]).map { $0.int(0) }
            let lines = try excerpts(of: changed)
            found = hits.map { row in
                PastVoiceMatch(speakerID: row.int(0), meetingID: row.int(1), meetingTitle: row.optionalString(6),
                               meetingDate: Date(timeIntervalSince1970: row.double(7)), speakerOrdinal: Int(row.int(10)),
                               talkSeconds: row.double(11), excerpt: lines[row.int(0)])
            }
            undo = try SpeakerUndo(speakers: speakerRows(changed + cleared))
            if !cleared.isEmpty {
                try run("UPDATE meeting_speakers SET entity_id = NULL, source = 'auto' WHERE id IN (SELECT value FROM json_each(?)) AND source = 'suggested'",
                        [.ids(cleared)])
            }
            try run("""
                UPDATE meeting_speakers SET entity_id = ?, source = 'suggested'
                WHERE id IN (SELECT value FROM json_each(?)) AND source <> 'user'
                """, [.integer(person), .ids(changed)])
        }
        if !found.isEmpty { try await commitEdit() }
        return PastVoiceSweep(entityID: live, matches: found, undo: undo)
    }

    /// One line per speaker to show next to a find: a line long enough to say something, trimmed. One query for all of them.
    private func excerpts(of speakerIDs: [Int64]) throws -> [Int64: String] {
        guard !speakerIDs.isEmpty else { return [:] }
        var result: [Int64: String] = [:]
        for row in try db.query("""
            SELECT speaker_id, text FROM (
                SELECT speaker_id, text, row_number() OVER (
                    PARTITION BY speaker_id ORDER BY (length(text) BETWEEN 40 AND 200) DESC, length(text) DESC, start) AS rank
                FROM segments WHERE speaker_id IN (SELECT value FROM json_each(?))
            ) WHERE rank = 1
            """, [.ids(speakerIDs)]) {
            let text = row.string(1).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result[row.int(0)] = text.count > 160 ? String(text.prefix(160)) + "…" : text }
        }
        return result
    }

    /// Whether this person has a saved voice the current model can use (the app offers the search only then).
    public func canLookForVoice(of entityID: Int64) throws -> Bool {
        try !db.query("""
            SELECT 1 FROM voice_profiles WHERE model_id = ?1 AND entity_id IN (SELECT id FROM entities WHERE id = ?2 OR merged_into = ?2) LIMIT 1
            """, [.text(DiarizationModels.embeddingModelID), .integer(entityID)]).isEmpty
    }
}
