// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Live labels (online clustering and the periodic re-clustering) and the reconstruction of turns.
@Suite("Diarization live labels")
struct DiarizationLiveTests {
    private func centres(_ count: Int, seed: UInt64 = 11) -> [[Float]] {
        var random = TestRandom(seed: seed)
        return (0..<count).map { _ in random.unitVector() }
    }

    // MARK: - Online clustering

    @Test func theSameVoiceKeepsItsLabel() {
        let c = centres(2)
        let online = OnlineClusterer(config: DiarizationConfig())
        var random = TestRandom(seed: 1)
        let first = online.assign(embeddings: [random.around(c[0], noise: 0.02), nil, nil], usable: [6, 0, 0])
        let second = online.assign(embeddings: [random.around(c[1], noise: 0.02), nil, nil], usable: [6, 0, 0])
        let again = online.assign(embeddings: [random.around(c[0], noise: 0.02), random.around(c[1], noise: 0.02), nil], usable: [6, 6, 0])
        #expect(first == [0, -1, -1] && second == [1, -1, -1])
        #expect(again == [0, 1, -1])
    }

    @Test func twoLocalSpeakersOfOneWindowNeverShareALabel() {
        let c = centres(1)
        let online = OnlineClusterer(config: DiarizationConfig())
        var random = TestRandom(seed: 2)
        _ = online.assign(embeddings: [random.around(c[0], noise: 0.02), nil, nil], usable: [6, 0, 0])
        let both = online.assign(embeddings: [random.around(c[0], noise: 0.02), random.around(c[0], noise: 0.02), nil], usable: [6, 6, 0])
        #expect(both[0] != both[1])
        #expect(Set(both.filter { $0 >= 0 }).count == 2)
    }

    @Test func aNewSpeakerNeedsEnoughSpeech() {
        let c = centres(2)
        let online = OnlineClusterer(config: DiarizationConfig())
        var random = TestRandom(seed: 3)
        _ = online.assign(embeddings: [random.around(c[0], noise: 0.02), nil, nil], usable: [6, 0, 0])
        // 1.5 s of an unknown voice: labelled with the nearest speaker, but no new speaker
        let brief = online.assign(embeddings: [random.around(c[1], noise: 0.02), nil, nil], usable: [1.5, 0, 0])
        #expect(brief == [0, -1, -1] && online.activeCount == 1)
        let long = online.assign(embeddings: [random.around(c[1], noise: 0.02), nil, nil], usable: [4, 0, 0])
        #expect(long == [1, -1, -1] && online.activeCount == 2)
    }

    @Test func aWeakMatchDoesNotMoveTheCentroid() {
        let c = centres(2)
        let online = OnlineClusterer(config: DiarizationConfig())
        var random = TestRandom(seed: 4)
        let anchor = random.around(c[0], noise: 0.02)
        _ = online.assign(embeddings: [anchor, nil, nil], usable: [6, 0, 0])
        for _ in 0..<5 { _ = online.assign(embeddings: [random.around(c[1], noise: 0.02), nil, nil], usable: [2, 0, 0]) }
        #expect(online.assign(embeddings: [anchor, nil, nil], usable: [6, 0, 0]) == [0, -1, -1])
        #expect(online.labelCount == 1)
    }

    // MARK: - Periodic re-clustering

    /// An online clusterer so strict that every voice splits into many live speakers, as the real one does a little.
    private func strictConfig() -> DiarizationConfig {
        var config = DiarizationConfig()
        config.onlineAssignDistance = 0.45
        config.onlineNewClusterSeconds = 1
        return config
    }

    @Test func reclusteringMergesOverSegmentedSpeakersAndKeepsTheLabelsInUse() {
        let c = centres(3)
        let plan: [[Int]] = (0..<90).map { [$0 / 30] }
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        let tracker = SpeakerTracker(config: strictConfig())
        for record in records { tracker.add(record) }
        let before = tracker.labels
        #expect(tracker.speakerCount > 3, "the strict online clusterer over-segments")

        let changed = tracker.recluster()
        #expect(tracker.speakerCount == 3)
        #expect(!changed.isEmpty)
        for speaker in 0..<3 {
            let windows = (speaker * 30)..<(speaker * 30 + 30)
            let counts = Dictionary(grouping: windows.map { before[$0][0] }, by: { $0 }).mapValues(\.count)
            let after = Set(windows.map { tracker.labels[$0][0] })
            // one label for the speaker, one the speaker already had; the dominant one when there is a clear one
            #expect(after.count == 1)
            #expect(counts[after.first!] != nil)
            let ranked = counts.sorted { $0.value > $1.value }
            if ranked.count == 1 || ranked[0].value > ranked[1].value { #expect(after == [ranked[0].key]) }
        }
        #expect(Set(tracker.labels.map { $0[0] }).count == 3)
    }

    @Test func aRecurringReclusteringChangesNothing() {
        let c = centres(2)
        let plan: [[Int]] = (0..<60).map { [$0 / 30] }
        let tracker = SpeakerTracker(config: DiarizationConfig())
        for record in SyntheticRecords.records(plan: plan, centres: c, noise: 0.03) { tracker.add(record) }
        tracker.recluster()
        let settled = tracker.labels
        #expect(tracker.recluster().isEmpty)
        #expect(tracker.labels == settled)
        // and a new window of a known voice takes its label
        var random = TestRandom(seed: 9)
        let next = tracker.add(WindowRecord(startSample: 60 * 32_000, classes: SyntheticRecords.classes(local: [0]),
                                            embeddings: [random.around(c[1], noise: 0.03), nil, nil], usableSeconds: [6, 0, 0]))
        #expect(next == [settled[59][0], -1, -1])
    }

    @Test func aSpeakerFoundOnlyByTheGlobalClusteringGetsAFreshLabel() {
        let c = centres(2)
        // one label in use, then a second voice that the online step (loose limit) swallowed into the first
        var config = DiarizationConfig()
        config.onlineAssignDistance = 2   // everything joins the first speaker
        let plan: [[Int]] = (0..<40).map { [$0 / 20] }
        let tracker = SpeakerTracker(config: config)
        for record in SyntheticRecords.records(plan: plan, centres: c, noise: 0.03) { tracker.add(record) }
        #expect(tracker.speakerCount == 1)
        tracker.recluster()
        #expect(tracker.speakerCount == 2)
        #expect(Set(tracker.labels[0..<20].map { $0[0] }) == [0])
        #expect(Set(tracker.labels[20...].map { $0[0] }) == [1])
    }

    @Test func reclusteringIsDueAfterTheConfiguredSeconds() {
        var config = DiarizationConfig()
        config.liveReclusterSeconds = 6   // 3 windows at the 2 s step
        let tracker = SpeakerTracker(config: config)
        let record = SyntheticRecords.records(plan: [[0]], centres: centres(1), noise: 0.03)[0]
        for _ in 0..<2 { tracker.add(record) }
        #expect(!tracker.isReclusterDue)
        tracker.add(record)
        #expect(tracker.isReclusterDue)
        tracker.recluster()
        #expect(!tracker.isReclusterDue)
    }

    // MARK: - Reconstruction

    @Test func finalTurnsFollowTheSegmentation() {
        // one 10 s window: speaker 0 for the first half, speaker 1 for the second; 5 s of 0 first, so ~ 5 s each
        var classes = [UInt8](repeating: 2, count: SegmentationGeometry.frames)
        for t in 0..<295 { classes[t] = 1 }
        var record = WindowRecord(startSample: 0, classes: classes, embeddings: [nil, nil, nil], usableSeconds: [5, 5, 0])
        record.embeddings = [nil, nil, nil]
        let turns = Reconstruction.finalTurns(records: [record], mapping: [[0, 1, -1]], speakerCount: 2, totalSamples: 160_000, config: DiarizationConfig())
        #expect(turns.count == 2)
        #expect(turns[0].speaker == 0 && abs(turns[0].start) < 0.05 && abs(turns[0].end - 4.98) < 0.05)
        #expect(turns[1].speaker == 1 && abs(turns[1].start - 4.98) < 0.05 && abs(turns[1].end - 9.95) < 0.1)
    }

    @Test func crosstalkKeepsBothSpeakers() {
        let classes = [UInt8](repeating: 4, count: SegmentationGeometry.frames)   // speakers 0 and 1 together
        let record = WindowRecord(startSample: 0, classes: classes, embeddings: [nil, nil, nil], usableSeconds: [5, 5, 0])
        let turns = Reconstruction.finalTurns(records: [record], mapping: [[0, 1, -1]], speakerCount: 2, totalSamples: 160_000, config: DiarizationConfig())
        #expect(Set(turns.map(\.speaker)) == [0, 1])
    }

    @Test func nearbyRunsJoinAndShortSpeakersDrop() {
        var active = [[Bool]](repeating: [Bool](repeating: false, count: 200), count: 2)
        for g in 10..<40 { active[0][g] = true }
        for g in 41..<60 { active[0][g] = true }       // 1 frame (17 ms) apart: one turn at the default 0.1 s
        for g in 100..<103 { active[1][g] = true }
        let config = DiarizationConfig()
        let turns = Reconstruction.turns(from: active, config: config)
        #expect(turns.filter { $0.speaker == 0 }.count == 1)
        #expect(Reconstruction.dropShortSpeakers(turns, minSeconds: 0.5).map(\.speaker) == [0])   // 0.84 s against 0.05 s
        #expect(Reconstruction.dropShortSpeakers(turns, minSeconds: 0).count == 2)
    }

    @Test func liveTurnsUseTheLabelsOfTheWindowThatOwnsTheFrame() {
        let classes = [UInt8](repeating: 1, count: SegmentationGeometry.frames)
        let records = (0..<6).map { WindowRecord(startSample: $0 * 32_000, classes: classes, embeddings: [nil, nil, nil], usableSeconds: [5, 0, 0]) }
        // the first windows call the speaker 0, the later ones 1 (a relabelling)
        let labels: [[Int]] = (0..<6).map { [$0 < 3 ? 0 : 1, -1, -1] }
        let turns = Reconstruction.liveTurns(records: records, labels: labels, totalSamples: 6 * 32_000 + 128_000, config: DiarizationConfig())
        #expect(Set(turns.map(\.speaker)) == [0, 1])
        let a = turns.first { $0.speaker == 0 }!, b = turns.first { $0.speaker == 1 }!
        #expect(a.start < 0.1 && abs(a.end - b.start) < 0.1)
    }

    @Test func rttmFormat() {
        let text = Reconstruction.rttm([SpeakerTurn(start: 1.5, end: 4, speaker: 1)], fileID: "m")
        #expect(text == "SPEAKER m 1 1.500 2.500 <NA> <NA> spk2 <NA> <NA>\n")
    }

    @Test func diarizeEndToEndOnSyntheticWindows() {
        let c = centres(2)
        let plan: [[Int]] = (0..<40).map { [$0 / 20] }
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        let result = Reconstruction.diarize(records: records, totalSamples: 39 * 32_000 + 160_000)
        #expect(result.speakerCount == 2)
        #expect(Set(result.turns.map(\.speaker)) == [0, 1])
        #expect(result.mapping.count == 40)
    }

    @Test func theLiveFoldKeepsItsFixedSizeInALongRecording() {
        let c = centres(3)
        // 520 windows (more than 17 minutes) and a joiner who speaks 7 windows (about 14 s) at the very end. The scaled fold of the
        // final pass would need 8 embeddings here and fold the joiner away; the live fold needs 6 and must keep the label shown.
        let plan: [[Int]] = Array(repeating: [0], count: 250) + Array(repeating: [1], count: 263) + Array(repeating: [2], count: 7)
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        let tracker = SpeakerTracker(config: DiarizationConfig())
        for record in records { tracker.add(record) }
        let joiner = tracker.labels[519][0]
        #expect(joiner >= 0 && joiner != tracker.labels[0][0] && joiner != tracker.labels[300][0])
        tracker.recluster()
        #expect(tracker.labels[519][0] == joiner, "the joiner keeps the live label")
        #expect(tracker.labels[515][0] == joiner)
        #expect(Set(tracker.labels.map { $0[0] }).count == 3)
        // the final pass, with the scaled fold, does fold the same joiner
        #expect(FinalClusterer.cluster(records: records, config: DiarizationConfig()).speakerCount == 2)
    }

    @Test func diarizeFoldsWithTheRealLengthOfTheRecording() {
        let c = centres(3)
        let plan: [[Int]] = Array(repeating: [0], count: 190) + Array(repeating: [2], count: 8) + Array(repeating: [1], count: 202)
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        let own = 399 * 32_000 + 160_000
        // 16 s of the third voice survives the 12 s fold of an 808 s recording ...
        #expect(Reconstruction.diarize(records: records, totalSamples: own).speakerCount == 3)
        // ... but not the 30 s fold of an hour-long one (the windows end early because the stored tail was silent)
        #expect(Reconstruction.diarize(records: records, totalSamples: 16_000 * 3_600).speakerCount == 2)
    }
}
