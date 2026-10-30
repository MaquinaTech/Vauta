// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Speaker separation at the end of a meeting: the window embeddings kept meanwhile (so a crash can still be
/// finalized) and the write of the speakers a diarization found.
extension MeetingStore {
    // MARK: Window embeddings

    /// Keeps analysed windows of a meeting being recorded. They are voice data: only the encrypted store and its
    /// journal ever hold them, until `SpeakerFinalizer` deletes them (`deleteDiarizationWindows`) or the meeting is deleted. Nothing is
    /// stored for a meeting that no longer exists.
    public func saveDiarizationWindows(_ windows: [Diarizer.SinkWindow], meetingID: Int64) throws {
        guard !windows.isEmpty else { return }
        try transaction {
            for window in windows {
                try run("""
                    INSERT OR REPLACE INTO diarization_windows(meeting_id, seq, data)
                    SELECT ?1, ?2, ?3 WHERE EXISTS (SELECT 1 FROM meetings WHERE id = ?1)
                    """, [.integer(meetingID), .integer(Int64(window.seq)), .blob(window.record.encoded())])
            }
        }
    }

    /// The windows kept for a meeting, in order. Rows that do not decode (damaged, or from a newer Vauta) are skipped.
    public func diarizationWindows(meetingID: Int64) throws -> [WindowRecord] {
        try db.query("SELECT data FROM diarization_windows WHERE meeting_id = ? ORDER BY seq", [.integer(meetingID)])
            .compactMap { WindowRecord(decoding: $0.data(0)) }
    }

    /// Meetings that still hold window embeddings and are not being recorded: their speakers were never finalized
    /// (the app quit or crashed during the recording).
    public func meetingsWithDiarizationWindows() throws -> [Int64] {
        try db.query("SELECT DISTINCT meeting_id FROM diarization_windows ORDER BY meeting_id")
            .map { $0.int(0) }.filter { $0 != activeMeetingID }
    }

    public func hasDiarizationWindows(meetingID: Int64) throws -> Bool {
        try !db.query("SELECT 1 FROM diarization_windows WHERE meeting_id = ? LIMIT 1", [.integer(meetingID)]).isEmpty
    }

    /// Deletes the meeting's window embeddings (the freed pages are zeroed by `secure_delete`).
    public func deleteDiarizationWindows(meetingID: Int64) async throws {
        guard try hasDiarizationWindows(meetingID: meetingID) else { return }
        try transaction { try run("DELETE FROM diarization_windows WHERE meeting_id = ?", [.integer(meetingID)]) }
        try await commitEdit()
    }

    // MARK: Writing the speakers

    /// Writes a diarization of the Others channel: aligns every transcript segment with the speaker turns,
    /// splits the segments where the speaker changes, and stores the speakers and who said each segment through
    /// `finalizeSpeakers`, which keeps everything the user decided. The Me channel is a single speaker (ordinal 1).
    ///
    /// Splits happen here, so this must run BEFORE translations are refined and before the meeting is analyzed or
    /// its minutes are written (see `SpeakerFinalizer`). `wordRuns` has the word times of segments, by segment ID,
    /// for cutting between words; without them a segment is cut in proportion to the time.
    ///
    /// With `recognizeVoices` (the user turned "Recognize voices across meetings" on), a speaker whose voice matches a
    /// saved voice is only SUGGESTED (cosine at or above `VoiceProfileThresholds.suggest`, source `suggested`: never a
    /// name until the user accepts it), and the voice of each speaker with enough speech is kept so the user can choose
    /// "Remember this voice". A name the user gave always wins (`finalizeSpeakers` never overwrites it). `ownVoice`
    /// lets the user's own saved voice be suggested for an Others speaker: imports pass true (one channel, so nobody
    /// is on Me), a live recording false (the user is on the Me channel); see `planVoices`.
    ///
    /// Returns the number of Others speakers written (0 when nothing was written: speakers are off for this
    /// meeting, or nobody spoke).
    @discardableResult
    public func applyDiarization(_ diarization: Diarization, to meetingID: Int64,
                                 wordRuns: [Int64: [AlignableSegment.Run]] = [:],
                                 recognizeVoices: Bool = false, ownVoice: Bool = false) async throws -> Int {
        guard try !speakersOff(meetingID: meetingID), !diarization.turns.isEmpty else { return 0 }
        let stored = try segments(of: meetingID)
        let others = stored.filter { $0.channel == .others }
        let aligned = SpeakerAligner(turns: diarization.turns).align(others.map {
            AlignableSegment(id: $0.id, start: $0.start, end: $0.end, text: $0.text, runs: wordRuns[$0.id] ?? [])
        })
        // "Speaker k" is numbered by first appearance in the transcript.
        var ordinals: [Int: Int] = [:]
        for alignment in aligned {
            for part in alignment.parts { if let speaker = part.speaker, ordinals[speaker] == nil { ordinals[speaker] = ordinals.count + 1 } }
        }
        guard !ordinals.isEmpty else { return 0 }

        var splits: [SegmentSplitRequest] = []
        var assignments: [SegmentSpeakerAssignment] = []
        var confidences: [Int: [Double]] = [:]
        let lengths = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0.text.count) })
        for alignment in aligned {
            var lastOffset = 0
            for (index, part) in alignment.parts.enumerated() {
                var rightOfSplit: Int?
                if index > 0 {
                    // a cut must fall strictly inside the text and after the previous one
                    guard part.offset > lastOffset, part.offset < (lengths[alignment.segmentID] ?? 0) else { continue }
                    splits.append(SegmentSplitRequest(segmentID: alignment.segmentID, offset: part.offset, time: part.time))
                    rightOfSplit = splits.count - 1
                    lastOffset = part.offset
                }
                guard let speaker = part.speaker, let ordinal = ordinals[speaker] else { continue }
                assignments.append(SegmentSpeakerAssignment(segmentID: alignment.segmentID, channel: .others, ordinal: ordinal,
                                                            confidence: part.confidence, overlap: part.overlap,
                                                            rightOfSplit: rightOfSplit))
                confidences[ordinal, default: []].append(part.confidence)
            }
        }
        let plan = recognizeVoices ? try planVoices(for: diarization, ordinals: ordinals, meetingID: meetingID, ownVoice: ownVoice) : VoicePlan()
        let matchByOrdinal = Dictionary(plan.matches.compactMap { speaker, match in ordinals[speaker].map { ($0, match) } }, uniquingKeysWith: { first, _ in first })
        let spreadByOrdinal = Dictionary(diarization.centroids.compactMap { c in ordinals[c.speaker].map { ($0, c.spread) } }, uniquingKeysWith: { first, _ in first })
        var drafts = ordinals.values.sorted().map { ordinal in
            let values = confidences[ordinal] ?? []
            let match = matchByOrdinal[ordinal]
            return SpeakerDraft(channel: .others, ordinal: ordinal, entityID: match?.entityID,
                                source: match == nil ? .auto : .suggested,
                                confidence: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                                voiceSpread: spreadByOrdinal[ordinal])
        }
        let mine = stored.filter { $0.channel == .me }
        if !mine.isEmpty {
            drafts.append(SpeakerDraft(channel: .me, ordinal: 1))
            assignments += mine.map { SegmentSpeakerAssignment(segmentID: $0.id, channel: .me, ordinal: 1) }
        }
        try await finalizeSpeakers(meetingID: meetingID, speakers: drafts, assignments: assignments, splits: splits, voices: plan.voices)
        // A suggestion counts as use only when the user accepts it (`assignSpeaker`).
        return ordinals.count
    }
}
