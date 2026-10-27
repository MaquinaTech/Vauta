// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A speaker's voice summary to keep with the finalized meeting, so the user can choose "Remember this voice" later.
/// Voice data: never printed.
public struct SpeakerVoiceDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var channel: Channel
    /// The ordinal the speaker was written with (before any renumbering for pinned rows).
    public var ordinal: Int
    public var modelID: String
    public var embedding: Data

    public init(channel: Channel, ordinal: Int, modelID: String, embedding: Data) {
        self.channel = channel
        self.ordinal = ordinal
        self.modelID = modelID
        self.embedding = embedding
    }

    public var description: String { "SpeakerVoiceDraft(ordinal: \(ordinal))" }
    public var debugDescription: String { description }
}

/// A person with saved voices, for Settings. Never includes the fingerprints.
public struct SavedVoice: Sendable, Identifiable, Hashable {
    public var id: Int64 { entityID }
    public let entityID: Int64
    /// The stored name (the user's own entity shows as "Me": see `displayName`).
    public let name: String
    public let isSelf: Bool
    public let fingerprints: Int
    /// When the user attested the most recent one.
    public let consentRecordedAt: Date
    /// The most recent time a suggestion from a fingerprint was accepted (nil: never).
    public let lastMatchedAt: Date?
    public let createdAt: Date
    /// Some fingerprint was made by the current embedding model, so recognition can use it.
    public let usable: Bool

    public var displayName: String { MeetingStore.displayName(name, isSelf: isSelf) }
    /// The last time the voice was useful: a match, else when it was saved.
    public var lastUsed: Date { lastMatchedAt ?? createdAt }
}

/// Recognizing voices across meetings: matching at finalization, the voice summaries kept for enrollment, and the
/// retention reminder. All of it is voice data and obeys the rules of `MeetingStore+VoiceProfiles.swift`.
extension MeetingStore {
    // MARK: Matching at finalization

    struct VoicePlan {
        var matches: [Int: VoiceMatch] = [:]
        var voices: [SpeakerVoiceDraft] = []
    }

    /// Decides names for the speakers of a diarization from the saved voices, and which voice summaries to keep.
    ///
    /// - `ordinals`: diarization speaker -> the ordinal it is written with.
    /// - `ownVoice`: the user's own saved voice may be suggested for a speaker. A live recording passes false (it has the
    ///   user on the Me channel); an imported file has one channel, so it passes true and "Is this you?" can be asked.
    /// - Never matches: a person the user rejected for this meeting, a person the user already gave to another speaker
    ///   of this meeting, a fingerprint of another embedding model, a speaker with too little clean speech.
    func planVoices(for diarization: Diarization, ordinals: [Int: Int], meetingID: Int64, ownVoice: Bool) throws -> VoicePlan {
        let model = DiarizationModels.embeddingModelID
        var excluded = Set<Int64>()
        if !ownVoice, let own = try selfEntityID() { excluded.insert(own) }
        excluded.formUnion(try db.query("SELECT entity_id FROM speaker_suggestion_rejections WHERE meeting_id = ?", [.integer(meetingID)]).map { $0.int(0) })
        excluded.formUnion(try db.query("SELECT entity_id FROM meeting_speakers WHERE meeting_id = ? AND source = 'user' AND entity_id IS NOT NULL AND channel = 'others'",
                                        [.integer(meetingID)]).map { $0.int(0) })
        let centroids = diarization.centroids.filter { ordinals[$0.speaker] != nil }
        var plan = VoicePlan()
        for match in VoiceMatcher.match(centroids, against: VoiceMatcher.templates(from: try voiceProfileEmbeddings(modelID: model), excluding: excluded)) {
            plan.matches[match.speaker] = match
        }
        for c in centroids where c.isCleanForVoice() {
            plan.voices.append(SpeakerVoiceDraft(channel: .others, ordinal: ordinals[c.speaker]!, modelID: model, embedding: VoiceMatcher.encode(c.vector)))
        }
        return plan
    }

    /// Replaces the voice summaries of a meeting (inside the transaction that writes its speakers).
    func replaceSpeakerVoices(meetingID: Int64, voices: [SpeakerVoiceDraft], ordinal: (Channel, Int) -> Int) throws {
        try run("DELETE FROM speaker_voices WHERE speaker_id IN (SELECT id FROM meeting_speakers WHERE meeting_id = ?)", [.integer(meetingID)])
        try run("DELETE FROM speaker_centroids WHERE speaker_id IN (SELECT id FROM meeting_speakers WHERE meeting_id = ?)", [.integer(meetingID)])
        for v in voices {
            // The same summary twice: one is consumed by "Remember this voice", the other (same 14 days) serves finding a voice in earlier meetings.
            for table in ["speaker_voices", "speaker_centroids"] {
                try run("""
                    INSERT OR REPLACE INTO \(table)(speaker_id, model_id, embedding, created_at)
                    SELECT id, ?4, ?5, ?6 FROM meeting_speakers WHERE meeting_id = ?1 AND channel = ?2 AND ordinal = ?3
                    """, [.integer(meetingID), .text(v.channel.storedCode), .integer(Int64(ordinal(v.channel, v.ordinal))),
                          .text(v.modelID), .blob(v.embedding), .real(Date.now.timeIntervalSince1970)])
            }
        }
    }

    // MARK: Enrollment

    /// Deletes the kept voice summaries of these speakers (inside the caller's transaction) because lines were moved
    /// between speakers: the summary is the centroid of the whole original cluster, so after a correction it may hold
    /// two people, and "Remember this voice" must never save it. The caller saves at once (`saveAfterVoiceDataRemoved`)
    /// when this returns true.
    func dropKeptVoices(of speakerIDs: [Int64?]) throws -> Bool {
        let ids = speakerIDs.compactMap { $0 }
        guard !ids.isEmpty else { return false }
        try run("DELETE FROM speaker_voices WHERE speaker_id IN (SELECT value FROM json_each(?))", [.ids(ids)])
        let summaries = db.changes
        try run("DELETE FROM speaker_centroids WHERE speaker_id IN (SELECT value FROM json_each(?))", [.ids(ids)])
        return summaries + db.changes > 0
    }

    /// Voice data (a kept summary or a lasting centroid) exists for the speakers matching `condition`: a deletion that
    /// removes them must be saved at once.
    func hasVoiceData(speakersWhere condition: String, _ params: [SQLiteValue?]) throws -> Bool {
        for table in ["speaker_voices", "speaker_centroids"] {
            if try !db.query("SELECT 1 FROM \(table) WHERE speaker_id IN (SELECT id FROM meeting_speakers WHERE \(condition)) LIMIT 1", params).isEmpty { return true }
        }
        return false
    }

    /// The speakers of a meeting whose voice was kept: "Remember this voice" is offered for them.
    public func speakersWithKeptVoice(meetingID: Int64) throws -> Set<Int64> {
        Set(try db.query("""
            SELECT v.speaker_id FROM speaker_voices v JOIN meeting_speakers s ON s.id = v.speaker_id
            WHERE s.meeting_id = ? AND v.model_id = ?
            """, [.integer(meetingID), .text(DiarizationModels.embeddingModelID)]).map { $0.int(0) })
    }

    /// "Remember this voice": saves the voice of a speaker the USER named as a fingerprint of that person. A suggestion
    /// must be accepted first (the user assigns it, which makes it theirs):
    /// a wrong suggestion must never add the wrong person's voice to a profile. `consentRecordedAt` is the moment the user attested that the person agreed. The kept summary then
    /// becomes the profile and is deleted. Returns the person and the new profile.
    @discardableResult
    public func rememberVoice(speakerID: Int64, consentRecordedAt: Date) async throws -> (entityID: Int64, profileID: Int64) {
        guard let speaker = try speaker(speakerID) else { throw Self.speakerGone }
        guard let entity = speaker.entityID, speaker.source == .user else { throw StoreError(.voiceNeedsPerson) }
        // The user's own voice is saved only by `rememberOwnVoice` (imports): in a live recording the user is the Me
        // channel, and a remote speaker assigned to "Me" must never become the user's voice.
        if try entity == selfEntityID(), try !isImported(meetingID: speaker.meetingID) { throw StoreError(.voiceNotAvailable) }
        guard let kept = try db.query("SELECT model_id, embedding FROM speaker_voices WHERE speaker_id = ?", [.integer(speakerID)]).first,
              kept.string(0) == DiarizationModels.embeddingModelID
        else { throw StoreError(.voiceNotAvailable) }
        let profile = try await addVoiceProfile(entityID: entity, modelID: kept.string(0), embedding: kept.data(1),
                                                consentRecordedAt: consentRecordedAt, sourceMeetingID: speaker.meetingID)
        try transaction { try run("DELETE FROM speaker_voices WHERE speaker_id = ?", [.integer(speakerID)]) }
        try await saveAfterVoiceDataRemoved()
        return (entity, profile)
    }

    /// "This is my voice": the speaker is the user (the user's own entity), and their voice is saved. The user attests
    /// for themselves, so the time is now.
    @discardableResult
    public func rememberOwnVoice(speakerID: Int64) async throws -> (entityID: Int64, undo: SpeakerUndo, profileID: Int64) {
        guard let speaker = try speaker(speakerID) else { throw Self.speakerGone }
        // Only in an imported recording: in a live one the user is the Me channel, and a remote speaker must never be
        // saved as the user (even when the user said nothing and the meeting has no Me speaker).
        guard try isImported(meetingID: speaker.meetingID) else { throw StoreError(.voiceNotAvailable) }
        guard try !db.query("SELECT 1 FROM speaker_voices WHERE speaker_id = ? AND model_id = ?",
                            [.integer(speakerID), .text(DiarizationModels.embeddingModelID)]).isEmpty else { throw StoreError(.voiceNotAvailable) }
        let own = try await selfEntity()
        let undo = try await assignSpeaker(speakerID, toEntity: own)
        do {
            let result = try await rememberVoice(speakerID: speakerID, consentRecordedAt: .now)
            return (own, undo, result.profileID)
        } catch {
            try? await self.undo(undo)
            throw error
        }
    }

    /// The meeting was made from an imported file (one audio channel).
    public func isImported(meetingID: Int64) throws -> Bool {
        try db.query("SELECT imported FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.int(0) == 1
    }

    // MARK: Suggestions

    /// "Not Ana": the speaker's suggested person is dropped, and never suggested again for this meeting. Returns what
    /// undoes it.
    @discardableResult
    public func rejectSuggestion(speakerID: Int64) async throws -> SpeakerUndo {
        let undo: SpeakerUndo = try transaction {
            guard let s = try speaker(speakerID) else { throw Self.speakerGone }
            var undo = try SpeakerUndo(speakers: speakerRows([speakerID]))
            guard s.source == .suggested, let entity = s.entityID else { return SpeakerUndo() }
            try run("INSERT OR IGNORE INTO speaker_suggestion_rejections(meeting_id, entity_id) VALUES (?, ?)", [.integer(s.meetingID), .integer(entity)])
            try run("UPDATE meeting_speakers SET entity_id = NULL, source = 'auto' WHERE id = ?", [.integer(speakerID)])
            undo.rejected = (s.meetingID, entity)
            return undo
        }
        try await commitEdit()
        return undo
    }

    // MARK: Listing and retention

    /// The people with saved voices, most recently saved first.
    public func savedVoices() throws -> [SavedVoice] {
        let model = DiarizationModels.embeddingModelID
        return try db.query("""
            SELECT p.entity_id, e.name, e.id IS (SELECT v FROM store_meta WHERE k = 'self_entity'), count(*), max(p.consent_recorded_at),
                   max(p.last_matched_at), max(p.created_at), max(p.model_id = ?1)
            FROM voice_profiles p JOIN entities e ON e.id = p.entity_id
            GROUP BY p.entity_id ORDER BY (p.entity_id IS (SELECT v FROM store_meta WHERE k = 'self_entity')) DESC, max(p.created_at) DESC, p.entity_id
            """, [.text(model)]).map { row in
            SavedVoice(entityID: row.int(0), name: row.string(1), isSelf: row.int(2) != 0, fingerprints: Int(row.int(3)),
                       consentRecordedAt: Date(timeIntervalSince1970: row.double(4)),
                       lastMatchedAt: row.optionalDouble(5).map { Date(timeIntervalSince1970: $0) },
                       createdAt: Date(timeIntervalSince1970: row.double(6)), usable: row.int(7) != 0)
        }
    }

    /// People whose saved voices were all last useful more than `VoiceProfileThresholds.unusedMonths` ago. Vauta only
    /// proposes deleting them; the user decides.
    public func unusedSavedVoices(now: Date = .now) throws -> [SavedVoice] {
        let limit = Calendar(identifier: .gregorian).date(byAdding: .month, value: -VoiceProfileThresholds.unusedMonths, to: now) ?? now
        return try savedVoices().filter { $0.lastUsed < limit }
    }

    /// Deletes the voice summaries kept for "Remember this voice" in every meeting (when recognition is turned off).
    /// Saved voices stay. Saved at once, like any deletion of voice data.
    @discardableResult
    public func deleteKeptSpeakerVoices() async throws -> Int {
        try await enforceKeptVoicePolicy(recognizing: false)
    }

    /// The rule for the voice summaries kept with meetings, applied at launch, after a restore and when the setting
    /// changes: with recognition off (the setting off, or speakers not separated) none are kept; with it on, one is
    /// kept for `VoiceProfileThresholds.keptSummaryDays` days after the meeting was processed. Saved at once when
    /// anything went. Returns how many summaries were deleted.
    @discardableResult
    public func enforceKeptVoicePolicy(recognizing: Bool, now: Date = .now) async throws -> Int {
        let limit = now.timeIntervalSince1970 - Double(VoiceProfileThresholds.keptSummaryDays) * 86_400
        let (n, centroids) = try transaction { () -> (Int, Int) in
            if recognizing {
                try run("DELETE FROM speaker_voices WHERE created_at < ?", [.real(limit)])
                let summaries = db.changes
                // The centroids used to look for a voice in earlier meetings live exactly as long as the summaries.
                try run("DELETE FROM speaker_centroids WHERE created_at < ?", [.real(limit)])
                return (summaries, db.changes)
            }
            try run("DELETE FROM speaker_voices", [])
            let summaries = db.changes
            try run("DELETE FROM speaker_centroids", [])
            return (summaries, db.changes)
        }
        if n + centroids > 0 { try await saveAfterVoiceDataRemoved() }
        return n
    }

    /// Number of centroids kept for finding voices in earlier meetings (tests and diagnostics; no content).
    public func meetingVoiceCentroidCount() throws -> Int {
        Int(try db.query("SELECT count(*) FROM speaker_centroids").first?.int(0) ?? 0)
    }

    /// Number of voice summaries kept (tests and diagnostics; no content).
    public func keptSpeakerVoiceCount() throws -> Int {
        Int(try db.query("SELECT count(*) FROM speaker_voices").first?.int(0) ?? 0)
    }
}
