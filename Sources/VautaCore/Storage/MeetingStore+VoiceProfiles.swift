// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Voice profiles: opt-in voice fingerprints of people, kept only when the user attests that the
/// person agreed. They live in the encrypted store and nowhere else: never in an export, a log, a
/// prompt, the vector index or the network. They are part of the encrypted backup and of Erase
/// Everything, die with their person (foreign key) and can be deleted per person or all at once.
extension MeetingStore {
    /// A person keeps at most this many fingerprints; adding one beyond it removes the oldest.
    public static let maxVoiceProfilesPerPerson = 10
    /// Upper bound for one embedding (a 512-dimension Float32 vector is 2 KB).
    public static let maxVoiceEmbeddingBytes = 16 << 10

    /// Stores a fingerprint of `entityID` (a person). `consentRecordedAt` is the moment the user
    /// attested that the person agreed; there is no way to add a profile without it. `modelID` names
    /// the embedding model and version: a profile is only usable with the model that made it. With
    /// ten fingerprints already, the ones of other models and then the oldest go first. Returns the
    /// profile's ID.
    @discardableResult
    public func addVoiceProfile(entityID: Int64, modelID: String, embedding: Data, consentRecordedAt: Date,
                                sourceMeetingID: Int64? = nil) async throws -> Int64 {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 200 else { throw StoreError("A voice profile needs the embedding model that made it.") }
        guard !embedding.isEmpty, embedding.count <= Self.maxVoiceEmbeddingBytes else { throw StoreError("The voice embedding has an invalid size.") }
        guard consentRecordedAt.timeIntervalSinceNow < 60 else { throw StoreError("The consent time can’t be in the future.") }
        let (id, trimmed): (Int64, Int) = try transaction {
            guard let live = try db.query("SELECT coalesce(merged_into, id) FROM entities WHERE id = ? AND kind = 'person'",
                                          [.integer(entityID)]).first?.int(0) else { throw KnowledgeError.entityGone }
            try run("""
                INSERT INTO voice_profiles(entity_id, model_id, embedding, created_at, source_meeting_id, consent_recorded_at)
                VALUES (?1, ?2, ?3, ?4, (SELECT id FROM meetings WHERE id = ?5), ?6)
                """, [.integer(live), .text(model), .blob(embedding), .real(Date.now.timeIntervalSince1970),
                      sourceMeetingID.map { .integer($0) }, .real(consentRecordedAt.timeIntervalSince1970)])
            let id = db.lastInsertRowID
            return (id, try trimVoiceProfiles(of: live, preferring: model))
        }
        try await commitEdit()
        if trimmed > 0 { try await saveAfterVoiceDataRemoved() }
        return id
    }

    /// Removes the surplus profiles of a person: other models' first, then the oldest.
    @discardableResult
    func trimVoiceProfiles(of entityID: Int64, preferring model: String? = nil) throws -> Int {
        try run("""
            DELETE FROM voice_profiles WHERE entity_id = ?1 AND id NOT IN (
                SELECT id FROM voice_profiles WHERE entity_id = ?1
                ORDER BY model_id IS ?2 DESC, created_at DESC, id DESC LIMIT \(Self.maxVoiceProfilesPerPerson))
            """, [.integer(entityID), model.map { .text($0) }])
        return db.changes
    }

    /// Sets when profiles last had a suggestion accepted. Not public: the only product path is accepting a suggestion
    /// (`assignSpeaker`); this exists for sample data and tests of the 12-month reminder.
    func markVoiceProfilesMatched(_ ids: [Int64], at date: Date = .now) async throws {
        guard !ids.isEmpty else { return }
        try transaction {
            try run("UPDATE voice_profiles SET last_matched_at = ? WHERE id IN (SELECT value FROM json_each(?))",
                    [.real(date.timeIntervalSince1970), .ids(ids)])
        }
        try await commitEdit()
    }

    /// The profiles of one person, or of everyone, newest first. Never includes the fingerprints.
    public func voiceProfiles(entityID: Int64? = nil) throws -> [VoiceProfile] {
        try db.query("""
            SELECT id, entity_id, model_id, created_at, source_meeting_id, consent_recorded_at, last_matched_at FROM voice_profiles
            WHERE ?1 IS NULL OR entity_id = ?1 ORDER BY created_at DESC, id DESC
            """, [entityID.map { .integer($0) }]).map { row in
            VoiceProfile(id: row.int(0), entityID: row.int(1), modelID: row.string(2),
                         createdAt: Date(timeIntervalSince1970: row.double(3)), sourceMeetingID: row.optionalInt(4),
                         consentRecordedAt: Date(timeIntervalSince1970: row.double(5)),
                         lastMatchedAt: row.optionalDouble(6).map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// The fingerprints that can be matched with embeddings of `modelID`. A profile made by another
    /// model (or another version of it) is unusable and never returned.
    public func voiceProfileEmbeddings(modelID: String) throws -> [VoiceProfileEmbedding] {
        try db.query("SELECT id, entity_id, embedding FROM voice_profiles WHERE model_id = ? ORDER BY entity_id, id",
                     [.text(modelID.trimmingCharacters(in: .whitespacesAndNewlines))]).map { VoiceProfileEmbedding(profileID: $0.int(0), entityID: $0.int(1), embedding: $0.data(2)) }
    }

    /// Deletes one fingerprint. Returns whether it existed.
    @discardableResult
    public func deleteVoiceProfile(_ id: Int64) async throws -> Bool {
        try await removeVoiceProfiles("DELETE FROM voice_profiles WHERE id = ?", [.integer(id)]) > 0
    }

    /// Deletes every voice of a person: their saved fingerprints and the voice summaries kept in the meetings where a
    /// speaker is named after them. Returns how many fingerprints there were.
    @discardableResult
    public func deleteVoiceProfiles(entityID: Int64) async throws -> Int {
        let (profiles, kept) = try transaction { () -> (Int, Int) in
            try run("DELETE FROM voice_profiles WHERE entity_id = ?", [.integer(entityID)])
            let profiles = db.changes
            let kept = try deleteKeptVoices(ofPerson: entityID)
            try dropOrphanSuggestions()
            return (profiles, kept)
        }
        if profiles + kept > 0 { try await saveAfterVoiceDataRemoved() }
        return profiles
    }

    /// Deletes the voice summaries and centroids kept for the speakers named after a person (or after the people merged into them).
    /// Runs inside the caller's transaction, before the speakers are un-named or deleted. Returns how many went.
    func deleteKeptVoices(ofPerson entityID: Int64) throws -> Int {
        var gone = 0
        for table in ["speaker_voices", "speaker_centroids"] {
            try run("""
                DELETE FROM \(table) WHERE speaker_id IN (SELECT id FROM meeting_speakers WHERE entity_id IN
                    (SELECT id FROM entities WHERE id = ?1 OR merged_into = ?1))
                """, [.integer(entityID)])
            gone += db.changes
        }
        return gone
    }

    /// A suggestion ("Is this Ana?") rests on a saved voice: when the person no longer has one, the suggestion goes (the
    /// speaker returns to unnamed). Names the user gave stay. Inside the caller's transaction.
    func dropOrphanSuggestions() throws {
        try run("""
            UPDATE meeting_speakers SET entity_id = NULL, source = 'auto'
            WHERE source = 'suggested' AND coalesce((SELECT merged_into FROM entities WHERE id = entity_id), entity_id)
                  NOT IN (SELECT entity_id FROM voice_profiles)
            """, [])
    }

    /// Deletes every fingerprint of everyone. Returns how many there were.
    ///
    /// The voice summaries kept for "Remember this voice" go too: "delete all" leaves no voice data of any kind.
    @discardableResult
    public func deleteAllVoiceProfiles() async throws -> Int {
        let (profiles, kept) = try transaction { () -> (Int, Int) in
            try run("DELETE FROM voice_profiles", [])
            let profiles = db.changes
            try run("DELETE FROM speaker_voices", [])
            var kept = db.changes
            try run("DELETE FROM speaker_centroids", [])
            kept += db.changes
            try dropOrphanSuggestions()
            return (profiles, kept)
        }
        if profiles + kept > 0 { try await saveAfterVoiceDataRemoved() }
        return profiles
    }

    /// Deleting biometric data is saved at once, like deleting a meeting: the snapshot without
    /// them is on disk before this returns (the freed pages are zeroed by `secure_delete`, and the
    /// journal that held the inserts goes with the snapshot).
    private func removeVoiceProfiles(_ sql: String, _ params: [SQLiteValue?]) async throws -> Int {
        let n = try transaction { () -> Int in
            try run(sql, params)
            let n = db.changes
            if n > 0 { try dropOrphanSuggestions() }
            return n
        }
        guard n > 0 else { return 0 }
        try await saveAfterVoiceDataRemoved()
        return n
    }

    /// Every path that removes fingerprints (deleting them, deleting or merging a person, the
    /// ten-profile cap) ends here, so none stays in the previous snapshot or the journal.
    func saveAfterVoiceDataRemoved() async throws {
        do { try await snapshot(compacting: false) } catch { throw StoreError(.deleteNotSaved, underlying: error) }
    }
}
