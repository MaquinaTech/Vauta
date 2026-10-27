// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Looking for a confirmed voice in earlier meetings: only on request, only with recognition on, suggestions never names,
/// the user's word wins, undoable, and the lasting centroids die with every path that deletes voice data.
extension MeetingStore {
    /// Makes every lasting centroid look like it came from another embedding model, and drops the short-lived summaries.
    func relabelCentroidsForTesting(model: String) throws {
        try transaction {
            try run("UPDATE speaker_centroids SET model_id = ?", [.text(model)])
            try run("DELETE FROM speaker_voices", [])
        }
    }
}

extension MeetingStore {
    /// `count` meetings with `speakers` Others speakers each, every one with a centroid, written in one transaction.
    func seedLibraryForTesting(meetings count: Int, speakers: Int, vector: [Float]) throws {
        try transaction {
            let blob = VoiceMatcher.encode(vector)
            for meeting in 0..<count {
                try run("INSERT INTO meetings(started_at, ended_at, title) VALUES (?, ?, ?)",
                        [.real(Date.now.timeIntervalSince1970 - Double(meeting) * 600), .real(Date.now.timeIntervalSince1970 - Double(meeting) * 600 + 300), .text("Meeting \(meeting)")])
                let id = db.lastInsertRowID
                for ordinal in 1...speakers {
                    try run("INSERT INTO meeting_speakers(meeting_id, channel, ordinal, talk_seconds) VALUES (?, 'others', ?, 60)", [.integer(id), .integer(Int64(ordinal))])
                    // Unrelated voices: orthogonal to the one searched for.
                    var other = [Float](repeating: 0, count: vector.count)
                    other[(meeting * speakers + ordinal) % other.count] = 1
                    try run("INSERT INTO speaker_centroids(speaker_id, model_id, embedding, created_at) VALUES (?, ?, ?, ?)",
                            [.integer(db.lastInsertRowID), .text(DiarizationModels.embeddingModelID), .blob(ordinal == 1 && meeting % 50 == 0 ? blob : VoiceMatcher.encode(other)), .real(Date.now.timeIntervalSince1970)])
                }
            }
        }
    }
}

@Suite("Voice history")
struct VoiceHistoryTests {
    typealias Meeting = VoiceRecognitionTests.Meeting

    /// Another meeting of the same store, with the same two voices (A on speaker 1, B on speaker 2), finalized with recognition on.
    static func earlier(_ m: Meeting, recognize: Bool = true) async throws -> Int64 {
        let id = try await m.store.startMeeting(at: .now.addingTimeInterval(-86_400))
        for (channel, start, text) in [(Channel.others, 10.0, "we should start with the budget"), (.me, 30, "agreed"), (.others, 120, "and then the roadmap review")] {
            try await m.store.append(Segment(channel: channel, start: start, end: start + 4, text: text, isFinal: true), to: id)
        }
        try await m.store.endMeeting(id, at: .now.addingTimeInterval(-86_000))
        _ = await SpeakerFinalizer.finalize(meetingID: id, in: m.store, run: m.run, recognizeVoices: recognize)
        return id
    }

    static func speaker(_ m: Meeting, _ meeting: Int64, _ ordinal: Int) async throws -> MeetingSpeaker {
        try #require(try await m.store.speakers(of: meeting).first { $0.channel == .others && $0.ordinal == ordinal })
    }

    /// A store with the current meeting and `count` earlier ones, none with a saved voice yet.
    static func world(earlier count: Int = 3) async throws -> (m: Meeting, earlier: [Int64], ana: Int64) {
        let m = try await Meeting()
        _ = await m.finalize()
        var ids: [Int64] = []
        for _ in 0..<count { ids.append(try await earlier(m)) }
        return (m, ids, try await m.person("Ana"))
    }

    // MARK: Matching

    @Test func theSearchOnlySuggestsAndNeverNames() async throws {
        let (m, ids, ana) = try await Self.world()
        _ = try await m.save(m.a, for: ana)
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(Set(sweep.matches.map(\.meetingID)) == Set(ids), "every earlier meeting, and not the current one")
        for id in ids {
            let first = try await Self.speaker(m, id, 1), second = try await Self.speaker(m, id, 2)
            #expect(first.source == .suggested && first.entityID == ana)
            #expect(first.name == nil && first.displayName == "Speaker 1", "a find is never a name")
            #expect(second.source == .auto && second.entityID == nil, "the other voice is untouched")
        }
        #expect(try await m.store.voiceProfiles(entityID: ana).first?.lastMatchedAt == nil, "a suggestion alone is not a use of the voice")
        let roster = SpeakerRoster(speakers: try await m.store.speakers(of: ids[0]), segments: try await m.store.segments(of: ids[0]))
        #expect(roster.entries.allSatisfy { $0.speaker.name == nil })
    }

    @Test func nothingHappensWithRecognitionOffOrWithoutASavedVoice() async throws {
        let (m, ids, ana) = try await Self.world()
        let none = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(none.isEmpty, "the person has no saved voice yet")
        #expect(try await m.store.canLookForVoice(of: ana) == false)
        _ = try await m.save(m.a, for: ana)
        #expect(try await m.store.canLookForVoice(of: ana))
        let off = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: false)
        #expect(off.isEmpty)
        for id in ids { #expect(try await Self.speaker(m, id, 1).source == .auto, "recognition off: nothing was written") }
    }

    @Test func theUsersWordAlwaysWins() async throws {
        let (m, ids, ana) = try await Self.world(earlier: 5)
        let bea = try await m.person("Bea")
        _ = try await m.save(m.a, for: ana)
        // 0: the user named speaker 1 as somebody else. 1: the user rejected Ana for this meeting.
        // 2: the user already gave Ana to the OTHER speaker. 3: speaker 1 is suggested as Bea (she has her own voice, a different one).
        try await m.store.assignSpeaker(try await Self.speaker(m, ids[0], 1).id, toEntity: bea)
        try await m.store.assignSpeaker(try await Self.speaker(m, ids[1], 1).id, toEntity: ana)
        try await m.store.rejectSuggestion(speakerID: try await Self.speaker(m, ids[1], 1).id)
        try await m.store.assignSpeaker(try await Self.speaker(m, ids[2], 2).id, toEntity: ana)
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(Set(sweep.matches.map(\.meetingID)) == [ids[3], ids[4]], "only the meetings where the user has not decided")
        let kept = try await Self.speaker(m, ids[0], 1)
        #expect(kept.source == .user && kept.entityID == bea && kept.name == "Bea")
        #expect(try await Self.speaker(m, ids[2], 2).name == "Ana")
        #expect(try await Self.speaker(m, ids[2], 1).source == .auto, "a person already given to another speaker is not suggested again")
    }

    @Test func aSpeakerSuggestedAsSomebodyElseIsLeftAlone() async throws {
        let (m, ids, ana) = try await Self.world(earlier: 1)
        let bea = try await m.person("Bea")
        _ = try await m.save(m.a, for: ana)
        _ = try await m.save(m.b, for: bea)
        // Each person has her own voice (A and B): the two searches fill the two speakers of the meeting independently.
        let first = try await m.store.suggestVoiceInPastMeetings(of: bea, recognizing: true)
        #expect(first.matches.contains { $0.meetingID == ids[0] })
        let second = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(second.matches.contains { $0.meetingID == ids[0] }, "each person finds their own speaker")
        #expect(try await Self.speaker(m, ids[0], 2).entityID == bea)
        #expect(try await Self.speaker(m, ids[0], 1).entityID == ana)
    }

    @Test func theUsersOwnVoiceIsNotSuggestedInALiveRecordingButIsInAnImport() async throws {
        let (m, ids, _) = try await Self.world(earlier: 1)
        let own = try await m.store.selfEntity()
        _ = try await m.store.addVoiceProfile(entityID: own, modelID: DiarizationModels.embeddingModelID, embedding: VoiceMatcher.encode(m.a), consentRecordedAt: .now)
        let live = try await m.store.suggestVoiceInPastMeetings(of: own, excludingMeeting: m.id, recognizing: true)
        #expect(live.isEmpty, "in a live recording the user is the Me channel")
        try await m.store.markImportedForTesting(ids[0])
        let imported = try await m.store.suggestVoiceInPastMeetings(of: own, excludingMeeting: m.id, recognizing: true)
        #expect(imported.matches.map(\.meetingID) == [ids[0]])
        let suggested = try await Self.speaker(m, ids[0], 1)
        #expect(suggested.source == .suggested && suggested.name == nil)
    }

    @Test func aCentroidOfAnotherModelIsNeverUsed() async throws {
        let (m, ids, ana) = try await Self.world(earlier: 1)
        _ = try await m.save(m.a, for: ana)
        try await m.store.relabelCentroidsForTesting(model: "other-model")
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(sweep.isEmpty)
        #expect(try await Self.speaker(m, ids[0], 1).source == .auto)
    }

    @Test func aMeetingWithoutSpeakersOrKeptCentroidsIsSkipped() async throws {
        let (m, ids, ana) = try await Self.world(earlier: 2)
        _ = try await m.save(m.a, for: ana)
        try await m.store.setSpeakersOff(true, meetingID: ids[0])
        let before = try await Self.earlier(m, recognize: false)
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(Set(sweep.matches.map(\.meetingID)) == [ids[1]], "recognition was off for \(before) and speakers are off for the first: they have no centroids")
    }

    // MARK: Undo and review

    @Test func undoPutsEverySpeakerBackAndAnAnswerIsOrdinary() async throws {
        let (m, ids, ana) = try await Self.world()
        _ = try await m.save(m.a, for: ana)
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        try await m.store.undo(sweep.undo)
        for id in ids {
            let s = try await Self.speaker(m, id, 1)
            #expect(s.source == .auto && s.entityID == nil)
        }
        // again, then answer: yes names (the user's act, undoable), no is remembered for the meeting
        let again = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        let yes = try await m.store.assignSpeaker(again.matches[0].speakerID, toEntity: ana)
        let no = try await m.store.rejectSuggestion(speakerID: again.matches[1].speakerID)
        #expect(try await m.store.speaker(again.matches[0].speakerID)?.name == "Ana")
        #expect(try await m.store.speaker(again.matches[1].speakerID)?.entityID == nil)
        try await m.store.undo(yes)
        try await m.store.undo(no)
        #expect(try await m.store.speaker(again.matches[0].speakerID)?.source == .suggested)
        #expect(try await m.store.speaker(again.matches[1].speakerID)?.source == .suggested, "undoing the No makes the suggestion come back")
        let second = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(second.isEmpty, "running it again is harmless: speakers already suggested as Ana are not found twice")
        for id in ids { #expect(try await Self.speaker(m, id, 1).source == .suggested) }
    }

    @Test func aRejectionIsRememberedForThatMeeting() async throws {
        let (m, ids, ana) = try await Self.world(earlier: 2)
        _ = try await m.save(m.a, for: ana)
        let first = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        let rejected = try #require(first.matches.first { $0.meetingID == ids[0] })
        try await m.store.rejectSuggestion(speakerID: rejected.speakerID)
        let second = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(second.isEmpty, "meeting 0 was rejected, meeting 1 is already suggested")
        #expect(try await Self.speaker(m, ids[0], 1).entityID == nil)
    }

    // MARK: Lifetime of the centroids

    @Test func centroidsLiveExactlyAsLongAsTheKeptSummariesAndGoWithRecognition() async throws {
        let (m, ids, ana) = try await Self.world(earlier: 1)
        _ = try await m.save(m.a, for: ana)
        #expect(try await m.store.meetingVoiceCentroidCount() == 4, "two clean speakers in each of two meetings")
        let soon = Date.now.addingTimeInterval(Double(VoiceProfileThresholds.keptSummaryDays - 1) * 86_400)
        _ = try await m.store.enforceKeptVoicePolicy(recognizing: true, now: soon)
        #expect(try await m.store.meetingVoiceCentroidCount() == 4, "inside the 14 days they stay")
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(sweep.matches.map(\.meetingID) == [ids[0]])
        let later = Date.now.addingTimeInterval(Double(VoiceProfileThresholds.keptSummaryDays + 1) * 86_400)
        _ = try await m.store.enforceKeptVoicePolicy(recognizing: true, now: later)
        #expect(try await m.store.keptSpeakerVoiceCount() == 0)
        #expect(try await m.store.meetingVoiceCentroidCount() == 0, "after the 14 days no voice vector of a speaker you did not choose is left")
        let after = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(after.isEmpty, "so there is nothing older to search")
        m.store = nil
        #expect(try await m.fx.open().meetingVoiceCentroidCount() == 0, "and the snapshot on disk has none")
    }

    @Test func recognitionOffDeletesTheCentroidsAtOnce() async throws {
        let (m, _, _) = try await Self.world(earlier: 1)
        #expect(try await m.store.meetingVoiceCentroidCount() == 4)
        _ = try await m.store.enforceKeptVoicePolicy(recognizing: false)
        #expect(try await m.store.meetingVoiceCentroidCount() == 0)
    }

    @Test func nothingIsKeptWhileRecognitionIsOff() async throws {
        let m = try await Meeting()
        _ = await m.finalize(recognize: false)
        _ = try await Self.earlier(m, recognize: false)
        #expect(try await m.store.meetingVoiceCentroidCount() == 0)
    }

    @Test func everyDeletionPathRemovesTheCentroids() async throws {
        // a meeting
        var (m, ids, _) = try await Self.world(earlier: 2)
        try await m.store.deleteMeeting(ids[0])
        #expect(try await m.store.meetingVoiceCentroidCount() == 4, "only that meeting's two went")
        // one person's voice: the centroid of the speaker named after them
        var ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        try await m.store.assignSpeaker(try await Self.speaker(m, ids[1], 1).id, toEntity: ana)
        #expect(try await m.store.deleteVoiceProfiles(entityID: ana) == 1)
        #expect(try await m.store.meetingVoiceCentroidCount() == 3)
        // the person
        (m, ids, ana) = try await Self.world(earlier: 1)
        _ = try await m.save(m.a, for: ana)
        try await m.store.assignSpeaker(try await Self.speaker(m, ids[0], 1).id, toEntity: ana)
        try await m.store.deleteEntity(ana)
        #expect(try await m.store.meetingVoiceCentroidCount() == 3)
        // all saved voices
        _ = try await m.store.deleteAllVoiceProfiles()
        #expect(try await m.store.meetingVoiceCentroidCount() == 0)
        // erase everything
        (m, _, _) = try await Self.world(earlier: 1)
        try await m.store.eraseEverything()
        #expect(try await m.store.rowCount("speaker_centroids") == 0)
        // the snapshot on disk
        (m, _, _) = try await Self.world(earlier: 1)
        _ = try await m.store.deleteAllVoiceProfiles()
        m.store = nil
        #expect(try await m.fx.open().rowCount("speaker_centroids") == 0)
    }

    @Test func aCorrectionThatMovesLinesDropsTheCentroidToo() async throws {
        let (m, ids, _) = try await Self.world(earlier: 1)
        let segments = try await m.store.segments(of: ids[0]).filter { $0.channel == .others }
        let target = try await Self.speaker(m, ids[0], 2)
        #expect(try await m.store.meetingVoiceCentroidCount() == 4)
        try await m.store.reassignSegment(segments[0].id, toSpeaker: target.id)
        #expect(try await m.store.meetingVoiceCentroidCount() == 2, "both speakers of that meeting may now hold two people, so neither is searched")
    }

    // MARK: Privacy

    @Test func centroidsAreNeverInExportsOrTheSweepResult() async throws {
        let (m, ids, ana) = try await Self.world(earlier: 1)
        _ = try await m.save(m.a, for: ana)
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        let bytes = VoiceMatcher.encode(m.a)
        let needles = [bytes.base64EncodedString(), bytes.map { String(format: "%02x", $0) }.joined(), "\(m.a[0])", "\(m.a[1])", "embedding", "cosine"]
        var outputs = ["\(sweep)", "\(sweep.matches)", String(reflecting: sweep.matches)]
        for id in ids + [m.id] {
            let export = try #require(try await m.store.meetingExport(id))
            for format in MeetingExportFormat.allCases {
                for options in [MeetingExportOptions(speakerLabels: .channels), MeetingExportOptions()] {
                    if let text = format.render(export, options: options) { outputs.append(text) }
                }
            }
        }
        for text in outputs { for needle in needles { #expect(!text.contains(needle), "\(needle.prefix(12))") } }
        #expect(!outputs.dropFirst(3).contains { $0.contains("Ana") }, "a suggestion from a saved voice is not in any export")
    }

    @Test func aFoundPersonIsNotASpeakerNameForSearchPromptsOrExports() async throws {
        let (m, ids, ana) = try await Self.world(earlier: 1)
        _ = try await m.save(m.a, for: ana)
        _ = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        // What search, prompts and exports read of a speaker is its name, and a suggestion has none.
        let names = try await m.store.segments(of: ids[0]).compactMap { $0.speaker?.name }
        #expect(names.isEmpty)
        // The one place a stored centroid is read besides the sweep is the store itself (see the source-scan test in VoiceRecognitionTests).
        #expect(try await m.store.speakers(of: ids[0]).allSatisfy { $0.name == nil })
    }

    @Test func theCentroidTableIsInTheSchemaAndDiesWithItsSpeaker() async throws {
        let (m, ids, _) = try await Self.world(earlier: 1)
        #expect(try await m.store.columnNames("speaker_centroids") == ["speaker_id", "model_id", "embedding", "created_at"])
        try await m.store.clearSpeakers(meetingID: ids[0])
        #expect(try await m.store.meetingVoiceCentroidCount() == 2)
    }

    // MARK: Evidence and cost

    @Test func eachFindCarriesWhatTheUserNeedsToJudgeIt() async throws {
        let (m, ids, ana) = try await Self.world(earlier: 1)
        _ = try await m.save(m.a, for: ana)
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        let match = try #require(sweep.matches.first { $0.meetingID == ids[0] })
        let speaker = try await Self.speaker(m, ids[0], 1)
        #expect(match.speakerOrdinal == 1)
        #expect(match.talkSeconds == speaker.talkSeconds && match.talkSeconds > 0)
        #expect(match.excerpt == "we should start with the budget", "a line of that very speaker")
    }

    @Test func searchingALargeLibraryStaysFast() async throws {
        let m = try await Meeting()
        _ = await m.finalize()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        try await m.store.seedLibraryForTesting(meetings: 2_000, speakers: 5, vector: m.a)
        #expect(try await m.store.meetingVoiceCentroidCount() >= 10_000)
        let clock = ContinuousClock()
        var sweep: PastVoiceSweep?
        let elapsed = try await clock.measure { sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true) }
        #expect(sweep?.matches.count == 40, "one find every 50 meetings")
        // A guard against work that grows with the square of the library (that takes minutes), not a speed test: it is generous on purpose.
        #expect(elapsed < .seconds(30), "the store is blocked while this runs: \(elapsed)")
    }
}
