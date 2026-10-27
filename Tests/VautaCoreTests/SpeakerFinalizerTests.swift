// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Finalization of the speakers at the end of a meeting (and after a crash): windows kept encrypted, clustering,
/// alignment, the write through the store, and the cleanup.
@Suite("Speaker finalization")
struct SpeakerFinalizerTests {
    /// 90 windows (2 s apart): speaker A talks in the first 45, speaker B in the next 45, so A speaks until about
    /// 0...98 s and B from about 82 s on, with the change near 90 s.
    private func records(seed: UInt64 = 3) -> [WindowRecord] {
        var random = TestRandom(seed: 1)
        let centres = (0..<2).map { _ in random.unitVector() }
        return SyntheticRecords.records(plan: (0..<90).map { [$0 < 45 ? 0 : 1] }, centres: centres, noise: 0.03, seed: seed)
    }

    private func sinkWindows(_ records: [WindowRecord]) -> [Diarizer.SinkWindow] {
        records.enumerated().map { Diarizer.SinkWindow(seq: $0.offset, record: $0.element) }
    }

    /// A meeting with an Others segment in A's part, one in B's part and one of Me, ended (as after Stop).
    private func meeting(_ store: MeetingStore) async throws -> (id: Int64, rows: [Int64]) {
        let id = try await store.startMeeting(at: .now)
        var rows: [Int64] = []
        for (channel, start, text) in [(Channel.others, 10.0, "we should start with the budget"), (.me, 30, "agreed"),
                                       (.others, 120, "and then the roadmap review")] {
            rows.append(try await store.append(Segment(channel: channel, start: start, end: start + 4, text: text, isFinal: true), to: id))
        }
        return (id, rows)
    }

    // MARK: Window records

    @Test func aWindowRecordSurvivesItsBytes() throws {
        let original = records()[7]
        let decoded = try #require(WindowRecord(decoding: original.encoded()))
        #expect(decoded.startSample == original.startSample && decoded.classes == original.classes)
        #expect(decoded.embeddings.map { $0 != nil } == original.embeddings.map { $0 != nil })
        #expect(decoded.embeddings[0]! == original.embeddings[0]!, "the embedding is bit for bit the same")
        #expect(decoded.usableSeconds == original.usableSeconds)
    }

    @Test func damagedWindowBytesAreRefused() {
        let good = records()[0].encoded()
        #expect(WindowRecord(decoding: Data()) == nil)
        #expect(WindowRecord(decoding: good.dropLast()) == nil)
        #expect(WindowRecord(decoding: good + [0]) == nil)
        var other = good
        other[0] = 9
        #expect(WindowRecord(decoding: other) == nil, "another version")
        var badClass = good
        badClass[9] = 200
        #expect(WindowRecord(decoding: badClass) == nil, "a class the decoder would index out of range")
    }

    @Test func windowRecordsNeverPrintTheirEmbeddings() {
        let text = "\(records()[0]) \(String(reflecting: records()[0]))"
        #expect(!text.contains("0."), "no number of any embedding in a description")
    }

    // MARK: Store

    @Test func windowsAreKeptEncryptedAndDeletedAtFinalization() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        try await store.flush()
        let (id, _) = try await meeting(store)
        // a recognisable embedding: a float pattern no encrypted file may contain
        let marker: [Float] = (0..<256).map { Float(bitPattern: 0x3E80_0000 + UInt32($0) * 0x101) }
        var record = records()[0]
        record.embeddings[0] = marker
        try await store.saveDiarizationWindows([Diarizer.SinkWindow(seq: 0, record: record)] + sinkWindows(records()).dropFirst(), meetingID: id)
        try await store.saveIfNeeded()
        let needle = marker.prefix(8).reduce(into: Data()) { data, value in withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        #expect(try Data(contentsOf: fx.journalURL).range(of: needle) == nil, "the journal holds no plaintext embedding")
        try await store.flush()
        #expect(try Data(contentsOf: fx.snapshotURL).range(of: needle) == nil, "neither does the snapshot")
        #expect(try await store.diarizationWindows(meetingID: id).count == 90)
        #expect(try await store.meetingsWithDiarizationWindows() == [], "a meeting being recorded is not 'interrupted'")

        try await store.endMeeting(id, at: .now)
        let outcome = await SpeakerFinalizer.finalize(meetingID: id, in: store)
        #expect(outcome == .written(2))
        #expect(try await store.diarizationWindows(meetingID: id).isEmpty, "window embeddings are deleted at finalization")
        #expect(try await store.hasDiarizationWindows(meetingID: id) == false)
    }

    @Test func windowsOfADeletedMeetingAreNotStored() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        try await store.saveDiarizationWindows(sinkWindows(records()), meetingID: 12345)
        #expect(try await store.diarizationWindows(meetingID: 12345).isEmpty)
    }

    // MARK: Finalization

    @Test func finalizationWritesSpeakersSplitsAndKeepsMeSingle() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let (id, rows) = try await meeting(store)
        try await store.endMeeting(id, at: .now.addingTimeInterval(200))
        let run = DiarizationRun(records: records(), totalSamples: 90 * 32_000 + 160_000)
        #expect(await SpeakerFinalizer.finalize(meetingID: id, in: store, run: run) == .written(2))
        let speakers = try await store.speakers(of: id)
        #expect(speakers.filter { $0.channel == .others }.map(\.ordinal) == [1, 2])
        #expect(speakers.filter { $0.channel == .me }.map(\.ordinal) == [1], "the microphone is one speaker")
        let stored = try await store.segments(of: id)
        #expect(stored.map(\.id) == [rows[0], rows[1], rows[2]], "short segments inside one speaker's turn are not split")
        #expect(stored[0].speaker?.ordinal == 1 && stored[2].speaker?.ordinal == 2)
        #expect(stored[1].channel == .me && stored[1].speaker?.ordinal == 1)
        #expect(stored.allSatisfy { $0.speaker?.id != nil }, "stored speakers have IDs")
    }

    @Test func finalizingAnHourOfSixSpeakersTakesSecondsNotMinutes() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        var random = TestRandom(seed: 4)
        let centres = (0..<6).map { _ in random.unitVector() }
        // 60 minutes = 1,800 windows in an optimized build (20 minutes in debug, which is about 100 times slower); the
        // speaker changes every 40 s in a fixed rotation
        #if DEBUG
        let windows = 600
        #else
        let windows = 1_800
        #endif
        let plan = (0..<windows).map { [($0 / 20) % 6] }
        let records = SyntheticRecords.records(plan: plan, centres: centres, noise: 0.03)
        let id = try await store.startMeeting(at: .now)
        for i in 0..<(windows / 4) {
            try await store.append(Segment(channel: i % 8 == 0 ? .me : .others, start: Double(i) * 9, end: Double(i) * 9 + 5,
                                           text: "segment number \(i) of the long meeting", isFinal: true), to: id)
        }
        try await store.endMeeting(id, at: .now.addingTimeInterval(3_600))
        let began = ContinuousClock.now
        let outcome = await SpeakerFinalizer.finalize(meetingID: id, in: store, run: DiarizationRun(records: records, totalSamples: windows * 32_000 + 160_000))
        let elapsed = ContinuousClock.now - began
        #expect(outcome == .written(6))
        // 15 s is the budget of an optimized build (measured: 0.27 s); an unoptimized debug build is about 100 times slower
        #if DEBUG
        let budget = Duration.seconds(60)
        #else
        let budget = Duration.seconds(15)
        #endif
        #expect(elapsed < budget, "finalizing 60 minutes took \(elapsed)")
    }

    @Test func aSegmentThatSpansASpeakerChangeIsSplitBetweenWords() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        // 8 words of 1 s, 80...88 s; B takes over at about 90 s in the synthetic windows, so make the change land inside
        let text = "one two three four five six seven eight"
        let row = try await store.append(Segment(channel: .others, start: 84, end: 96, text: text, isFinal: true), to: id)
        try await store.endMeeting(id, at: .now.addingTimeInterval(200))
        let words = text.split(separator: " ").enumerated().map { index, word in
            AlignableSegment.Run(range: (text.distance(of: word))..<(text.distance(of: word) + word.count), start: 84 + Double(index) * 1.5,
                                 end: 85.5 + Double(index) * 1.5)
        }
        let run = DiarizationRun(records: records(), totalSamples: 90 * 32_000 + 160_000)
        #expect(await SpeakerFinalizer.finalize(meetingID: id, in: store, run: run, wordRuns: [row: words]) == .written(2))
        let stored = try await store.segments(of: id)
        #expect(stored.count == 2, "split in two")
        #expect(stored.map(\.text).joined(separator: " ") == text, "no word is lost or repeated")
        #expect(stored[0].speaker?.ordinal == 1 && stored[1].speaker?.ordinal == 2)
        #expect(stored[0].end <= stored[1].start + 0.001)
    }

    @Test func userDecisionsSurviveFinalization() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let (id, rows) = try await meeting(store)
        try await store.endMeeting(id, at: .now.addingTimeInterval(200))
        let run = DiarizationRun(records: records(), totalSamples: 90 * 32_000 + 160_000)
        await SpeakerFinalizer.finalize(meetingID: id, in: store, run: run)
        let second = try #require(try await store.speakers(of: id).first { $0.channel == .others && $0.ordinal == 2 })
        let ana = try await store.renameSpeaker(second.id, to: "Ana")
        // the user moves the first Others segment to Ana by hand, then the speakers are finalized again
        try await store.reassignSegment(rows[0], toSpeaker: second.id)
        await SpeakerFinalizer.finalize(meetingID: id, in: store, run: run)
        let after = try await store.segments(of: id)
        #expect(after.first { $0.id == rows[0] }?.speaker?.name == "Ana", "the hand-made assignment is kept")
        #expect(try await store.speakers(of: id).contains { $0.entityID == ana.entityID && $0.source == .user })
    }

    @Test func aMeetingWithSpeakersOffIsLeftAloneAndItsWindowsAreDeleted() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let (id, _) = try await meeting(store)
        try await store.endMeeting(id, at: .now.addingTimeInterval(200))
        try await store.setSpeakersOff(true, meetingID: id)
        try await store.saveDiarizationWindows(sinkWindows(records()), meetingID: id)
        #expect(await SpeakerFinalizer.finalize(meetingID: id, in: store) == .skipped)
        #expect(try await store.speakers(of: id).isEmpty)
        #expect(try await store.segments(of: id).allSatisfy { $0.speaker == nil })
        #expect(try await store.hasDiarizationWindows(meetingID: id) == false)
    }

    @Test func diarizationOffLeavesTheStoreExactlyAsBefore() async throws {
        // The same meeting twice: once as an app without speaker separation records it, once as an app with it turned
        // off for this meeting finalizes it (windows present). Segments, speakers and the exports match.
        let (fx1, fx2) = (StoreFixture(), StoreFixture())
        defer { withExtendedLifetime((fx1, fx2)) {} }
        let plain = try fx1.open()
        let off = try fx2.open()
        var snapshots: [[String]] = []
        for (store, withWindows) in [(plain, false), (off, true)] {
            let (id, _) = try await meeting(store)
            if withWindows {
                try await store.setSpeakersOff(true, meetingID: id)
                try await store.saveDiarizationWindows(sinkWindows(records()), meetingID: id)
            }
            try await store.endMeeting(id, at: Date(timeIntervalSince1970: 2_000_000_000))
            if withWindows { await SpeakerFinalizer.finalize(meetingID: id, in: store, run: DiarizationRun(records: records(), totalSamples: 3_000_000)) }
            let rows = try await store.segments(of: id).map { "\($0.channel.rawValue)|\($0.start)|\($0.end)|\($0.text)|\(String(describing: $0.speaker))" }
            let cited = try await store.citableSegments(id).map { "\($0.id)|\(String(describing: $0.speaker))|\($0.text)" }
            let speakers = try await store.speakers(of: id).map(\.displayName)
            snapshots.append(rows + cited + speakers + ["windows:\(try await store.hasDiarizationWindows(meetingID: id))"])
        }
        #expect(snapshots[0] == snapshots[1])
        #expect(snapshots[0].last == "windows:false")
    }

    @Test func theSpeakerSwitchTravelsInBackups() {
        #expect(BackupPreferences.allowed["separateSpeakers"] == .bool)
        let restored = BackupPreferences(values: ["separateSpeakers": .bool(false)])
        #expect(restored.values["separateSpeakers"] == .bool(false))
        #expect(BackupPreferences(values: ["separateSpeakers": .string("no")]).isEmpty, "a value of the wrong type is skipped")
    }

    @Test func aSegmentConstructedWithoutSpeakerDataIsUnchanged() {
        let segment = Segment(channel: .others, start: 1, end: 2, text: "hi", isFinal: true)
        #expect(segment.speaker == nil && segment.words.isEmpty)
        let tagged = segment.with(speaker: SpeakerTag(ordinal: 2))
        #expect(tagged.text == "hi" && tagged.start == 1 && tagged.end == 2 && tagged.speaker?.ordinal == 2)
        #expect(segment.with(speaker: nil).speaker == nil)
    }

    // MARK: Crash recovery

    @Test func aCrashedRecordingIsFinalizedAtTheNextLaunch() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        let (id, rows) = try await meeting(store!)
        try await store!.saveDiarizationWindows(sinkWindows(records()), meetingID: id)
        try await store!.saveIfNeeded()
        store = nil   // like kill -9: no endMeeting, no finalization

        store = try fx.open(recover: true)
        #expect(try await store!.meetingsWithDiarizationWindows() == [id], "the windows came back from the encrypted journal")
        #expect(try await store!.speakers(of: id).isEmpty)
        let recovered = await SpeakerFinalizer.recoverInterrupted(in: store!)
        #expect(recovered == [id])
        let speakers = try await store!.speakers(of: id)
        #expect(speakers.filter { $0.channel == .others }.count == 2)
        let stored = try await store!.segments(of: id)
        #expect(stored.map(\.id) == rows)
        #expect(stored[0].speaker?.ordinal == 1 && stored[2].speaker?.ordinal == 2)
        #expect(try await store!.meetingsWithDiarizationWindows() == [], "deleted once finalized")
        #expect(await SpeakerFinalizer.recoverInterrupted(in: store!) == [], "nothing to do the second time")
    }

    @Test func aCrashedRecordingGetsNoSpeakersWhenSeparationWasTurnedOffSince() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        let (id, _) = try await meeting(store!)
        try await store!.saveDiarizationWindows(sinkWindows(records()), meetingID: id)
        try await store!.saveIfNeeded()
        store = nil

        store = try fx.open(recover: true)
        let recovered = await SpeakerFinalizer.recoverInterrupted(in: store!, enabled: false)
        #expect(recovered == [id])
        #expect(try await store!.speakers(of: id).isEmpty, "turned off: the meeting is stored exactly as before")
        #expect(try await store!.meetingsWithDiarizationWindows() == [], "and the voice data is gone")
    }

    @Test func minutesWaitForTheSpeakers() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        let (id, _) = try await meeting(store!)
        try await store!.saveDiarizationWindows(sinkWindows(records()), meetingID: id)
        try await store!.saveIfNeeded()
        store = nil
        store = try fx.open(recover: true)
        let service = LLMService(store: store!, providers: TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }))
        await service.meetingEnded(id)
        #expect(try await store!.speakers(of: id).isEmpty == false, "speakers are written before the minutes are queued")
        #expect(try await store!.hasDiarizationWindows(meetingID: id) == false)
        #expect(try await store!.jobs(for: id).contains { $0.kind == .minutes })
    }

    @Test func deletingAMeetingDeletesItsWindows() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let (id, _) = try await meeting(store)
        try await store.endMeeting(id, at: .now.addingTimeInterval(200))
        try await store.saveDiarizationWindows(sinkWindows(records()), meetingID: id)
        try await store.deleteMeeting(id)
        #expect(try await store.meetingsWithDiarizationWindows() == [])
    }
}

private extension String {
    /// Offset in Characters of a substring of this string.
    func distance(of word: Substring) -> Int { distance(from: startIndex, to: word.startIndex) }
}
