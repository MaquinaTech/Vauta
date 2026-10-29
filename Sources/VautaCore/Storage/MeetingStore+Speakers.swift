// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The speakers of a meeting: who said each segment, and the edits the user makes to that.
///
/// Naming precedence: a name the user chose is ground truth and is never overwritten;
/// otherwise "Speaker k" (a saved voice only suggests). Calendar attendees are suggestions the UI
/// offers; they are never stored as an assignment. Nothing names a speaker from what the transcript says.
/// Every mutation is one transaction, journaled like any other write.
///
/// `segments.speaker` keeps its frozen 'me'/'others' values: a speaker belongs to one channel, and
/// no operation here moves a segment to the other channel. The channel of a segment is therefore
/// decided before `append`: the pipelines that attribute by voice (an echo of the room in the
/// microphone, an imported file where profiles tell Me from Others) must diarize before they insert
/// the segments, so the full-text index and the talk time never see a segment change channel.
extension MeetingStore {
    static let speakerGone = StoreError(.speakerGone)
    static let segmentGone = StoreError(.segmentGone)

    // MARK: Reading

    private static let speakerSelect = """
        SELECT sp.id, sp.meeting_id, sp.channel, sp.ordinal, sp.entity_id, e.name,
               e.id IS (SELECT v FROM store_meta WHERE k = 'self_entity'), sp.source, sp.confidence, sp.talk_seconds
        FROM meeting_speakers sp LEFT JOIN entities e ON e.id = sp.entity_id
        """

    private static func meetingSpeaker(_ row: Row) -> MeetingSpeaker {
        MeetingSpeaker(id: row.int(0), meetingID: row.int(1), channel: Channel(storedSpeaker: row.string(2)), ordinal: Int(row.int(3)),
                       entityID: row.optionalInt(4), entityName: row.optionalString(5), entityIsSelf: row.int(6) != 0,
                       source: MeetingSpeaker.Source(rawValue: row.string(7)) ?? .auto,
                       confidence: row.optionalDouble(8), talkSeconds: row.double(9))
    }

    /// The speakers of a meeting: the user's channel first, then Others, each by ordinal. Empty
    /// for a meeting without speaker data.
    public func speakers(of meetingID: Int64) throws -> [MeetingSpeaker] {
        try db.query(Self.speakerSelect + " WHERE sp.meeting_id = ? ORDER BY sp.channel = 'others', sp.ordinal",
                     [.integer(meetingID)]).map(Self.meetingSpeaker)
    }

    public func speaker(_ id: Int64) throws -> MeetingSpeaker? {
        try db.query(Self.speakerSelect + " WHERE sp.id = ?", [.integer(id)]).first.map(Self.meetingSpeaker)
    }

    // MARK: Finalization

    /// Writes the speaker set a finished diarization produced, and which speaker said each segment.
    ///
    /// - A row is pinned when it has `source == .user` or when a segment the user decided by hand
    ///   (`speaker_locked`: reassigned, split or merged) points at it. The pinned rows are never
    ///   deleted. The other rows of the meeting are replaced by `speakers`.
    /// - A user row is NEVER overwritten: when `speakers` has the same channel and ordinal, only its
    ///   confidence is refreshed (its person and source stay); when it does not, the row stays as it
    ///   is. Finalizing again therefore keeps every name the user chose.
    /// - Ordinals need not be stable between runs: each pinned row is matched with the new cluster
    ///   that shares the most segment time with it (by the current `speaker_id` of its unlocked
    ///   segments in `assignments`), and that cluster takes the row's ordinal, so a name, a merge or a hand-moved
    ///   segment never moves to another voice. A pinned row nothing matches is matched with the
    ///   cluster that has its exact channel and ordinal, if any. Other clusters whose ordinal a pinned
    ///   row holds are renumbered to a free one.
    /// - A draft whose person no longer exists is stored unnamed (`.auto`); one whose person was
    ///   merged follows the person that remains.
    /// - `assignments` are the complete set for the meeting: when it or `speakers` is not empty, every segment
    ///   that is not locked is cleared first and then assigned (`speaker_id`, confidence, overlap).
    ///   A segment the user decided by hand (reassigned, split or merged: `speaker_locked`) is never
    ///   touched. An assignment to an ordinal that neither `speakers` nor a pinned row holds throws; one that a pinned row holds attaches to that row.
    /// - `splits` are the aligner's cuts at speaker changes, applied first and in the same
    ///   transaction (see `MeetingStore+SpeakerSplit.swift` for ordering and translations): a crash
    ///   never leaves a meeting half finalized. They do not lock, so a later diarization still owns
    ///   the parts, and they work on a meeting being recorded (periodic finalization). Each segment
    ///   may appear several times (A, B, A turns): every request names the ORIGINAL segment and an
    ///   `offset` into its original text, and they are applied from the last offset to the first, so the
    ///   left part keeps the ID and each request gets its own right part. An assignment with
    ///   `rightOfSplit` addresses the right part of that request. The first part is addressed by the
    ///   segment's ID. A segment the user locked is not split: its requests are skipped, and so are
    ///   the assignments that address their right parts.
    /// - Nothing is written for a meeting whose speakers the user turned off (`setSpeakersOff`).
    /// - `voices` are the voice summaries to keep for "Remember this voice" (only while voice recognition is on); the
    ///   ones kept before for this meeting are replaced.
    /// - Talk time is recomputed from the segments.
    public func finalizeSpeakers(meetingID: Int64, speakers drafts: [SpeakerDraft],
                                 assignments: [SegmentSpeakerAssignment] = [],
                                 splits: [SegmentSplitRequest] = [],
                                 voices: [SpeakerVoiceDraft] = []) async throws {
        var keys = Set<String>()
        for draft in drafts {
            guard draft.ordinal >= 1, draft.source != .user, keys.insert("\(draft.channel.rawValue)#\(draft.ordinal)").inserted else {
                throw StoreError("The speaker set is not valid.")
            }
        }
        guard Set(splits.map { [$0.segmentID, Int64($0.offset)] }).count == splits.count,
              assignments.allSatisfy({ a in a.rightOfSplit.map { splits.indices.contains($0) && splits[$0].segmentID == a.segmentID } ?? true })
        else { throw StoreError("The speaker set is not valid.") }
        var removedVoices = false
        try transaction {
            guard let meeting = try db.query("SELECT speakers_off FROM meetings WHERE id = ?", [.integer(meetingID)]).first,
                  meeting.int(0) == 0 else { return }
            // Voice summaries about to be replaced or cascaded away: the snapshot without them is saved after the edit.
            removedVoices = try hasVoiceData(speakersWhere: "meeting_id = ?", [.integer(meetingID)])
            var rightParts = [Int64?](repeating: nil, count: splits.count)
            // Last cut first: the left part keeps the ID, so the offsets into the original text stay valid.
            for index in splits.indices.sorted(by: { (splits[$0].segmentID, -splits[$0].offset) < (splits[$1].segmentID, -splits[$1].offset) }) {
                let request = splits[index]
                guard let row = try db.query("SELECT speaker_locked FROM segments WHERE id = ? AND meeting_id = ?",
                                             [.integer(request.segmentID), .integer(meetingID)]).first
                else { throw Self.segmentGone }
                if row.int(0) != 0 { continue }
                rightParts[index] = try splitInTransaction(request.segmentID, atCharacter: request.offset, time: request.time,
                                                           rightSpeaker: nil, byUser: false).rightID
            }
            let assignments: [SegmentSpeakerAssignment] = assignments.compactMap { a in
                var a = a
                if let index = a.rightOfSplit {
                    guard let right = rightParts[index] else { return nil }
                    a.segmentID = right
                }
                return a
            }
            let pinned = try pinnedSpeakers(meetingID)
            let remap = try pinnedOrdinalRemap(pinned, drafts, assignments, meetingID)
            func final(_ channel: Channel, _ ordinal: Int) -> Int { remap["\(channel.rawValue)#\(ordinal)"] ?? ordinal }
            let kept = Set(drafts.map { "\($0.channel.rawValue)#\(final($0.channel, $0.ordinal))" })
            let people = Dictionary(try db.query("""
                SELECT id, coalesce(merged_into, id) FROM entities WHERE kind = 'person' AND id IN (SELECT value FROM json_each(?))
                """, [.ids(drafts.compactMap(\.entityID))]).map { ($0.int(0), $0.int(1)) }, uniquingKeysWith: { first, _ in first })
            let existing = try db.query("SELECT id, channel, ordinal FROM meeting_speakers WHERE meeting_id = ?", [.integer(meetingID)])
            let gone = existing.filter { !pinned.keys.contains($0.int(0)) && !kept.contains("\($0.string(1))#\($0.int(2))") }
            try run("DELETE FROM meeting_speakers WHERE id IN (SELECT value FROM json_each(?))", [.ids(gone.map { $0.int(0) })])
            for draft in drafts {
                var (entity, source) = (draft.entityID.flatMap { people[$0] }, draft.source)
                if source == .auto || entity == nil { (entity, source) = (nil, .auto) }
                try run("""
                    INSERT INTO meeting_speakers(meeting_id, channel, ordinal, entity_id, source, confidence) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(meeting_id, channel, ordinal) DO UPDATE SET
                        confidence = excluded.confidence,
                        entity_id = CASE WHEN meeting_speakers.source = 'user' THEN meeting_speakers.entity_id ELSE excluded.entity_id END,
                        source = CASE WHEN meeting_speakers.source = 'user' THEN 'user' ELSE excluded.source END
                    """, [.integer(meetingID), .text(draft.channel.storedCode), .integer(Int64(final(draft.channel, draft.ordinal))),
                          entity.map { .integer($0) }, .text(source.rawValue), draft.confidence.map { .real(min(1, max(0, $0))) }])
            }
            if !assignments.isEmpty || !drafts.isEmpty {
                try run("""
                    UPDATE segments SET speaker_id = NULL, speaker_confidence = NULL, overlap = 0
                    WHERE meeting_id = ? AND speaker_locked = 0
                    """, [.integer(meetingID)])
            }
            for a in assignments {
                guard let row = try db.query("SELECT id FROM meeting_speakers WHERE meeting_id = ? AND channel = ? AND ordinal = ?",
                                             [.integer(meetingID), .text(a.channel.storedCode), .integer(Int64(final(a.channel, a.ordinal)))]).first
                else { throw StoreError("The speaker set is not valid.") }
                // Stores from 0.1.0 keep 'Yo'/'Otros' in `segments.speaker`.
                try run("""
                    UPDATE segments SET speaker_confidence = ?1, overlap = ?2, speaker_id = ?3
                    WHERE id = ?4 AND meeting_id = ?5 AND speaker_locked = 0 AND speaker IN (?6, ?7)
                    """, [a.confidence.map { .real(min(1, max(0, $0))) }, .integer(a.overlap ? 1 : 0), .integer(row.int(0)),
                          .integer(a.segmentID), .integer(meetingID), .text(a.channel.storedCode), .text(a.channel == .me ? "Yo" : "Otros")])
            }
            try recomputeTalkTimeInTransaction(meetingID)
            try replaceSpeakerVoices(meetingID: meetingID, voices: voices, ordinal: final)
        }
        if !splits.isEmpty { vectorCache = nil }
        try await commitEdit()
        if removedVoices { try await saveAfterVoiceDataRemoved() }
    }

    /// SQL for the speakers of `?1` that finalization must keep: the user's, and the ones segments the
    /// user decided by hand point at.
    private static let pinnedCondition = """
        meeting_id = ?1 AND (source = 'user' OR id IN
            (SELECT speaker_id FROM segments WHERE meeting_id = ?1 AND speaker_locked = 1 AND speaker_id IS NOT NULL))
        """

    private func pinnedSpeakers(_ meetingID: Int64) throws -> [Int64: (channel: Channel, ordinal: Int)] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT id, channel, ordinal FROM meeting_speakers WHERE " + Self.pinnedCondition,
                                                      [.integer(meetingID)]).map { ($0.int(0), (Channel(storedSpeaker: $0.string(1)), Int($0.int(2)))) })
    }

    /// Where the clusters of a new diarization must be numbered so that pinned rows keep their
    /// voice: `"<channel>#<new ordinal>"` to the final ordinal, only for the ones that change.
    private func pinnedOrdinalRemap(_ pinnedByID: [Int64: (channel: Channel, ordinal: Int)], _ drafts: [SpeakerDraft],
                                    _ assignments: [SegmentSpeakerAssignment], _ meetingID: Int64) throws -> [String: Int] {
        guard !pinnedByID.isEmpty else { return [:] }
        var reserved: [Channel: Set<Int>] = [:]
        for p in pinnedByID.values { reserved[p.channel, default: []].insert(p.ordinal) }
        // Shared segment time between each pinned row and each new cluster. Only the segments the diarizer
        // placed count: the ones the user moved are the user's word, not evidence of whose voice the row is.
        var weights: [[Int64]: Double] = [:]
        let spans = Dictionary(try db.query("""
            SELECT id, speaker_id, max(end - start, 0) FROM segments
            WHERE meeting_id = ?1 AND speaker_locked = 0 AND speaker_id IN (SELECT id FROM meeting_speakers WHERE \(Self.pinnedCondition))
            """, [.integer(meetingID)]).map { ($0.int(0), ($0.int(1), $0.double(2))) }, uniquingKeysWith: { first, _ in first })
        for a in assignments {
            guard let (speaker, seconds) = spans[a.segmentID], pinnedByID[speaker]?.channel == a.channel else { continue }
            weights[[speaker, Int64(a.ordinal)], default: 0] += seconds
        }
        var map: [String: Int] = [:]
        var usedPinned = Set<Int64>(), matched: [Channel: Set<Int>] = [:]
        for (pair, _) in weights.sorted(by: { ($0.value, -$0.key[1]) > ($1.value, -$1.key[1]) }) {
            guard let pinned = pinnedByID[pair[0]], !usedPinned.contains(pair[0]), !(matched[pinned.channel]?.contains(Int(pair[1])) ?? false) else { continue }
            usedPinned.insert(pair[0])
            matched[pinned.channel, default: []].insert(Int(pair[1]))
            map["\(pinned.channel.rawValue)#\(pair[1])"] = pinned.ordinal
        }
        // A pinned row nothing matched takes the cluster with its own channel and ordinal, unless another row has it.
        for (id, pinned) in pinnedByID where !usedPinned.contains(id) && !(matched[pinned.channel]?.contains(pinned.ordinal) ?? false) {
            usedPinned.insert(id)
            matched[pinned.channel, default: []].insert(pinned.ordinal)
        }
        // The rest keep their number when free; the ones whose number a pinned row holds take the next free one.
        var drafted: [Channel: Set<Int>] = [:]
        for d in drafts { drafted[d.channel, default: []].insert(d.ordinal) }
        var wanted = drafted
        for a in assignments { wanted[a.channel, default: []].insert(a.ordinal) }
        for channel in Channel.allCases {
            let ordinals = (wanted[channel] ?? []).filter { !(matched[channel]?.contains($0) ?? false) }.sorted()
            var taken = reserved[channel] ?? []
            // An ordinal only an assignment names (no draft) that a pinned row holds attaches to that row.
            let colliding = ordinals.filter { taken.contains($0) && drafted[channel]?.contains($0) == true }
            taken.formUnion(ordinals.filter { !taken.contains($0) })
            for ordinal in colliding {
                var free = 1
                while taken.contains(free) { free += 1 }
                taken.insert(free)
                map["\(channel.rawValue)#\(ordinal)"] = free
            }
        }
        return map
    }

    /// Talk time of each speaker of the meeting: the sum of the lengths of its segments.
    public func recomputeTalkTime(meetingID: Int64) async throws {
        try transaction { try recomputeTalkTimeInTransaction(meetingID) }
        try await commitEdit()
    }

    func recomputeTalkTimeInTransaction(_ meetingID: Int64) throws {
        try run("""
            UPDATE meeting_speakers SET talk_seconds = coalesce(
                (SELECT SUM(max(end - start, 0)) FROM segments WHERE speaker_id = meeting_speakers.id AND echo <> 1), 0)
            WHERE meeting_id = ?
            """, [.integer(meetingID)])
    }

    // MARK: Naming

    /// The user says who a speaker is (`entityID`), or clears the name (nil).
    ///
    /// Both are the user's decision and survive re-finalization: the row gets source `user`. A cleared speaker is a `user`
    /// row with no person, which shows as "Speaker k" and is pinned like a named one, so no later pass can name it.
    /// Rule: voice-profile matching never writes a name on a `user` row (it may only offer a suggestion).
    /// A merged entity is followed to the one that remains. Returns what undoes it.
    @discardableResult
    public func assignSpeaker(_ speakerID: Int64, toEntity entityID: Int64?) async throws -> SpeakerUndo {
        let undo: SpeakerUndo = try transaction {
            guard try !db.query("SELECT 1 FROM meeting_speakers WHERE id = ?", [.integer(speakerID)]).isEmpty else { throw Self.speakerGone }
            var undo = try SpeakerUndo(speakers: speakerRows([speakerID]))
            if let entityID {
                guard let live = try db.query("SELECT coalesce(merged_into, id) FROM entities WHERE id = ? AND kind = 'person'",
                                              [.integer(entityID)]).first?.int(0) else { throw KnowledgeError.entityGone }
                // Accepting "Is this Ana?" is the use of Ana's saved voice that counts for the retention reminder.
                if try !db.query("SELECT 1 FROM meeting_speakers WHERE id = ? AND source = 'suggested' AND entity_id = ?", [.integer(speakerID), .integer(live)]).isEmpty {
                    try run("UPDATE voice_profiles SET last_matched_at = ? WHERE entity_id = ?", [.real(Date.now.timeIntervalSince1970), .integer(live)])
                }
                try run("UPDATE meeting_speakers SET entity_id = ?, source = 'user' WHERE id = ?", [.integer(live), .integer(speakerID)])
                // Tasks that had this speaker as their owner now belong to the person.
                undo.ownerMoves = try moveSpeakerOwners(speakerID, to: live)
            } else {
                // Cleared: the tasks that took the person from this speaker go back to the speaker.
                undo.ownerMoves = try moveSpeakerOwners(speakerID, to: nil)
                try run("UPDATE meeting_speakers SET entity_id = NULL, source = 'user' WHERE id = ?", [.integer(speakerID)])
            }
            return undo
        }
        try await commitEdit()
        return undo
    }

    /// The tasks owned through speaker `speakerID` follow the speaker's person: `to` a person when the speaker is named, back to the
    /// speaker (`nil`) when the name is cleared. A task keeps its `owner_speaker_id` after the move, so clearing the name finds it; a
    /// task whose owner the user set by hand to someone else is left alone. Returns what changed, for the undo.
    func moveSpeakerOwners(_ speakerID: Int64, to new: Int64?) throws -> [SpeakerUndo.OwnerMove] {
        let old = try db.query("SELECT entity_id FROM meeting_speakers WHERE id = ?", [.integer(speakerID)]).first?.optionalInt(0)
        var moves: [SpeakerUndo.OwnerMove] = []
        let rows = try db.query("SELECT id, owner_id FROM tasks WHERE owner_speaker_id = ?1 AND (owner_id IS NULL OR owner_id IS ?2)",
                                [.integer(speakerID), old.map { .integer($0) }])
        for row in rows {
            let before = row.optionalInt(1)
            guard before != new else { continue }
            try run("UPDATE tasks SET owner_id = ? WHERE id = ?", [new.map { .integer($0) }, .integer(row.int(0))])
            try syncOwnerEdge(row.int(0), new)
            moves.append(.init(task: row.int(0), before: before, after: new))
        }
        return moves
    }

    /// In how many meetings this person spoke: meetings where a speaker with at least one line was assigned to them by the
    /// user (typed, or a suggestion accepted). Never a guess: a calendar suggestion is not counted.
    public func speakerMeetingCount(entityID: Int64) throws -> Int {
        try Int(db.query("SELECT count(*) FROM (\(Self.spokeMeetings))", [.integer(entityID)]).first?.int(0) ?? 0)
    }

    /// The meetings where the person (parameter ?1) spoke, as a SELECT of meeting IDs: the one definition behind
    /// the count and the card's list of meetings.
    static let spokeMeetings = """
        SELECT DISTINCT s.meeting_id FROM meeting_speakers s
        WHERE s.entity_id IN (SELECT id FROM entities WHERE id = ?1 OR merged_into = ?1)
          AND s.source = 'user'
          AND EXISTS (SELECT 1 FROM segments g WHERE g.speaker_id = s.id)
        """

    /// The user types who a speaker is: the speaker is assigned, by the user, to the person called
    /// `name` (an existing one with that name or alias, else a new one). It never renames a person:
    /// correcting "this isn't Ana, it's Bea" must not rename Ana everywhere nor move her voice
    /// profiles; renaming a person is an action on the person. Throws when several people have the
    /// name, so the UI can ask which one. Returns the person's ID and what undoes it (the speaker as it
    /// was, and the removal of the person this created if nothing else uses them by then).
    @discardableResult
    public func renameSpeaker(_ speakerID: Int64, to name: String) async throws -> SpeakerRename {
        let clean = Self.clean(name, max: 200)
        guard !clean.isEmpty else { throw KnowledgeError.emptyName }
        let norm = TextKeys.norm(clean)
        let result: SpeakerRename = try transaction {
            guard try !db.query("SELECT 1 FROM meeting_speakers WHERE id = ?", [.integer(speakerID)]).isEmpty else { throw Self.speakerGone }
            var undo = try SpeakerUndo(speakers: speakerRows([speakerID]))
            let matches = try db.query("""
                SELECT DISTINCT coalesce(e.merged_into, e.id) FROM aliases a JOIN entities e ON e.id = a.entity_id
                WHERE a.alias_norm = ? AND e.kind = 'person'
                """, [.text(norm)])
            guard matches.count <= 1 else { throw StoreError(.speakerNameAmbiguous) }
            let entity: Int64
            if let match = matches.first {
                entity = match.int(0)
            } else {
                try run("INSERT INTO entities(kind, name, source, confirmed, created_at) VALUES ('person', ?, 'user', 1, ?)",
                        [.text(clean), .real(Date.now.timeIntervalSince1970)])
                entity = db.lastInsertRowID
                try addAlias(clean, norm: norm, to: entity, source: "user")
                undo.createdPerson = entity
            }
            undo.ownerMoves = try moveSpeakerOwners(speakerID, to: entity)
            try run("UPDATE meeting_speakers SET entity_id = ?, source = 'user' WHERE id = ?", [.integer(entity), .integer(speakerID)])
            return SpeakerRename(entityID: entity, undo: undo)
        }
        try await commitEdit()
        return result
    }

    // MARK: Merge, reassign, split

    /// Adds an empty speaker to a finalized meeting, for the case where the diarizer put two people in one
    /// cluster: the user then moves segments to it (`reassignSegment`, `splitSegment(rightSpeaker:)`).
    /// It takes the next free ordinal of `channel`. Segments that point at it lock it in place, like
    /// any pinned row; a speaker nobody uses is replaced by the next finalization. Returns the speaker
    /// and what undoes it (the row goes away again while no segment points at it).
    @discardableResult
    public func addSpeaker(meetingID: Int64, channel: Channel) async throws -> (speaker: MeetingSpeaker, undo: SpeakerUndo) {
        let result: (MeetingSpeaker, SpeakerUndo) = try transaction {
            guard let meeting = try db.query("SELECT speakers_off FROM meetings WHERE id = ?", [.integer(meetingID)]).first else { throw Self.speakerGone }
            guard meeting.int(0) == 0 else { throw StoreError(.speakersOff) }
            let next = try db.query("SELECT coalesce(max(ordinal), 0) + 1 FROM meeting_speakers WHERE meeting_id = ? AND channel = ?",
                                    [.integer(meetingID), .text(channel.storedCode)])[0].int(0)
            try run("INSERT INTO meeting_speakers(meeting_id, channel, ordinal, source) VALUES (?, ?, ?, 'auto')",
                    [.integer(meetingID), .text(channel.storedCode), .integer(next)])
            let id = db.lastInsertRowID
            guard let created = try speaker(id) else { throw Self.speakerGone }
            return (created, SpeakerUndo(createdSpeaker: id))
        }
        try await commitEdit()
        return result
    }

    /// Merges speaker `source` into `target` (the diarizer split one person in two): its segments
    /// move to `target` (and are locked there, so a new diarization keeps the merge), `source` is
    /// deleted. Both must be speakers of the same meeting and channel.
    /// The name that wins is the stronger one (user over suggested/none); between two
    /// different names the user chose, `target`'s stays. Returns what undoes it.
    @discardableResult
    public func mergeSpeaker(_ source: Int64, into target: Int64) async throws -> SpeakerUndo {
        var removedVoices = false
        let undo: SpeakerUndo = try transaction {
            guard let s = try speaker(source), let t = try speaker(target) else { throw Self.speakerGone }
            guard s.id != t.id else { return SpeakerUndo() }
            guard s.meetingID == t.meetingID, s.channel == t.channel else {
                throw StoreError(.speakerMismatch)
            }
            func rank(_ speaker: MeetingSpeaker) -> Int {
                guard speaker.entityID != nil else { return 0 }
                return switch speaker.source { case .user: 3; case .suggested: 1; case .auto: 0 }
            }
            let undo = try SpeakerUndo(speakers: speakerRows([s.id, t.id]),
                                       segments: segmentStates("WHERE speaker_id = ?", [.integer(s.id)]))
            try run("UPDATE segments SET speaker_id = ?, speaker_locked = 1 WHERE speaker_id = ?", [.integer(t.id), .integer(s.id)])
            if rank(s) > rank(t), let entity = s.entityID {
                try run("UPDATE meeting_speakers SET entity_id = ?, source = ?, confidence = ? WHERE id = ?",
                        [.integer(entity), .text(s.source.rawValue), s.confidence.map { .real($0) }, .integer(t.id)])
            }
            else if s.source == .user, s.entityID == nil, t.entityID == nil, t.source != .user {
                // The user cleared this speaker's name: the merged speaker stays the user's decision.
                try run("UPDATE meeting_speakers SET source = 'user' WHERE id = ?", [.integer(t.id)])
            }
            // Its kept voice summary goes with it (cascade): saved at once, like every removal of voice data.
            removedVoices = try hasVoiceData(speakersWhere: "id = ?", [.integer(s.id)])
            try run("DELETE FROM meeting_speakers WHERE id = ?", [.integer(s.id)])
            try recomputeTalkTimeInTransaction(t.meetingID)
            return undo
        }
        try await commitEdit()
        if removedVoices { try await saveAfterVoiceDataRemoved() }
        return undo
    }

    /// Says that one segment was spoken by `speakerID` (nil: by nobody in particular). The user's
    /// word replaces the diarizer's: the segment's confidence is cleared and the segment is locked,
    /// so a later diarization does not undo it. The speaker must belong to the segment's meeting and
    /// channel. Returns what undoes it.
    @discardableResult
    public func reassignSegment(_ segmentID: Int64, toSpeaker speakerID: Int64?) async throws -> SpeakerUndo {
        var removedVoices = false
        let undo: SpeakerUndo = try transaction {
            guard let seg = try db.query("SELECT meeting_id, speaker FROM segments WHERE id = ?", [.integer(segmentID)]).first else {
                throw Self.segmentGone
            }
            let meeting = seg.int(0)
            if let speakerID {
                guard let target = try speaker(speakerID) else { throw Self.speakerGone }
                guard target.meetingID == meeting, target.channel == Channel(storedSpeaker: seg.string(1)) else {
                    throw StoreError(.speakerMismatch)
                }
            }
            let undo = try SpeakerUndo(segments: segmentStates("WHERE id = ?", [.integer(segmentID)]))
            // The kept voice summary describes the whole original cluster: once lines move between speakers it may
            // hold two people, so it is dropped for both (see `dropKeptVoices`).
            let before = try db.query("SELECT speaker_id FROM segments WHERE id = ?", [.integer(segmentID)]).first?.optionalInt(0)
            if before != speakerID { removedVoices = try dropKeptVoices(of: [before, speakerID]) }
            try run("UPDATE segments SET speaker_id = ?, speaker_confidence = NULL, speaker_locked = 1 WHERE id = ?",
                    [speakerID.map { .integer($0) }, .integer(segmentID)])
            try recomputeTalkTimeInTransaction(meeting)
            return undo
        }
        try await commitEdit()
        if removedVoices { try await saveAfterVoiceDataRemoved() }
        return undo
    }
}
