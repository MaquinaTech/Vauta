// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Foundation
import Testing
@testable import VautaCore

/// Regression tests for the diarization review: clustering edge cases, live labels, the abandoned recording and the
/// reader of provisional labels.
@Suite("Diarization review fixes")
struct DiarizationReviewTests {
    private func centres(_ count: Int, seed: UInt64 = 11) -> [[Float]] {
        var random = TestRandom(seed: seed)
        return (0..<count).map { _ in random.unitVector() }
    }

    /// A unit vector at Euclidean distance `distance` from `a`.
    private func vector(at distance: Float, from a: [Float], seed: UInt64) -> [Float] {
        var random = TestRandom(seed: seed)
        let cosine = 1 - distance * distance / 2
        let r = random.unitVector()
        let orthogonal = VectorMath.normalised(zip(r, a).map { $0 - VectorMath.dot(r, a) * $1 })
        return VectorMath.normalised(zip(a, orthogonal).map { cosine * $0 + (1 - cosine * cosine).squareRoot() * $1 })
    }

    // MARK: Established-speaker guard

    @Test func aFragmentNextToARefusedEstablishedSpeakerStillJoinsIt() {
        // A and B (40 points each) are 0.671 apart: refused at 0.70 with a 0.05 margin. C (15 points) is 0.691 from
        // A and 0.904 from B: it lies inside A's cut and must not become a third speaker.
        let a: [Float] = [0, 0], b: [Float] = [0.671, 0], c: [Float] = [0.0823, 0.686]
        var random = TestRandom(seed: 3)
        func cloud(_ centre: [Float], _ count: Int) -> [[Float]] {
            (0..<count).map { _ in [centre[0] + 0.002 * random.gaussian(), centre[1] + 0.002 * random.gaussian()] }
        }
        let points = cloud(a, 40) + cloud(b, 40) + cloud(c, 15)
        let plain = AgglomerativeClustering.cluster(vectors: points, threshold: 0.70)
        #expect(Set(plain).count == 2, "without the guard A and B are one speaker and C another")
        let guarded = AgglomerativeClustering.cluster(vectors: points, threshold: 0.70, establishedSize: 30, establishedMargin: 0.05)
        #expect(Set(guarded).count == 2)
        #expect(guarded[0] != guarded[40], "A and B stay apart")
        #expect(guarded[80] == guarded[0], "C joins A, the speaker whose cut it is inside")
    }

    @Test func twoStageClusteringKeepsAnEstablishedPairApartInsideOneChunk() {
        let a = centres(1, seed: 4)[0]
        let b = vector(at: 0.67, from: a, seed: 12)
        var random = TestRandom(seed: 6)
        var vectors: [[Float]] = []
        for i in 0..<120 { vectors.append(random.around(i % 2 == 0 ? a : b, noise: 0.003)) }
        var config = DiarizationConfig()
        config.maxDirectEmbeddings = 100     // two-stage
        config.stageChunkSize = 3_000        // one chunk holds both voices
        let staged = FinalClusterer.agglomerate(vectors, config: config)
        config.maxDirectEmbeddings = 10_000
        let direct = FinalClusterer.agglomerate(vectors, config: config)
        #expect(Set(direct).count == 2, "one stage: the guard keeps the pair apart")
        #expect(SyntheticRecords.samePartition(staged, direct), "and so does the first stage of the two-stage path")
    }

    // MARK: Phantom speakers and dropped speakers

    @Test func anExtraLocalSpeakerDoesNotBecomeAPhantomSpeaker() {
        let c = centres(3, seed: 31)
        // two real speakers; in 2 windows the segmentation opens a third local speaker (too short to be a cluster)
        var plan: [[Int]] = Array(repeating: [0, 1], count: 40)
        plan[10] = [0, 1, 2]
        plan[25] = [0, 1, 2]
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        let result = FinalClusterer.cluster(records: records, config: DiarizationConfig())
        #expect(result.speakerCount == 2)
        #expect(result.mapping[10].allSatisfy { $0 < 2 } && result.mapping[10][0] != result.mapping[10][1])
    }

    @Test func aSpeakerWithTooLittleSpeechIsDroppedAndTheOthersAreRenumbered() {
        let c = centres(3, seed: 52)
        let plan: [[Int]] = Array(repeating: [0], count: 60) + Array(repeating: [1], count: 15) + Array(repeating: [2], count: 60)
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        var keep = DiarizationConfig()
        keep.minSpeakerSeconds = 0
        let all = Reconstruction.diarize(records: records, totalSamples: 135 * 32_000 + 160_000, config: keep)
        #expect(all.speakerCount == 3)
        var drop = DiarizationConfig()
        drop.minSpeakerSeconds = 50
        let kept = Reconstruction.diarize(records: records, totalSamples: 135 * 32_000 + 160_000, config: drop)
        #expect(kept.speakerCount == 2)
        #expect(Set(kept.turns.map(\.speaker)) == [0, 1], "no hole in the numbering")
        #expect(!kept.mapping.joined().contains(2))
    }

    // MARK: Live labels

    @Test func aNewcomerWhoJoinedRecentlyKeepsTheirLabelWhenTheLabelsAreReclustered() {
        let c = centres(3, seed: 63)
        // A and B talk for 80 s of window starts, then C joins: 8 embeddings, fewer than the final fold's 10
        let plan: [[Int]] = Array(repeating: [0, 1], count: 40) + Array(repeating: [0, 1, 2], count: 8)
        let tracker = SpeakerTracker(config: DiarizationConfig())
        for record in SyntheticRecords.records(plan: plan, centres: c, noise: 0.03) { tracker.add(record) }
        let newcomer = tracker.labels.last![2]
        #expect(newcomer >= 0)
        tracker.recluster()
        #expect(tracker.labels.last![2] == newcomer, "the label already shown to the newcomer survives the re-clustering")
        #expect(tracker.labels.last![2] != tracker.labels.last![0] && tracker.labels.last![2] != tracker.labels.last![1])
    }

    @Test func liveAgreementIsHighForSeparableVoicesAndEmptyForNothing() {
        let c = centres(3, seed: 74)
        let plan: [[Int]] = (0..<120).map { [$0 / 40] }
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        let result = LiveAgreement.measure(records: records)
        #expect(result.agreement > 0.97)
        #expect(result.finalSpeakers == 3 && result.labelledFrames > 0 && result.labelledFrames <= result.speechFrames)
        let none = LiveAgreement.measure(records: [])
        #expect(none.agreement == 0 && none.speechFrames == 0)
    }

    @Test func oneVoiceThatTheSegmentationOpensTwiceIsNotShatteredByTheGuard() {
        // every window has two local speakers with the same voice: all conflicts, nothing to split
        let c = centres(1, seed: 85)
        let records = SyntheticRecords.records(plan: Array(repeating: [0, 0], count: 60), centres: c, noise: 0.03)
        let result = FinalClusterer.cluster(records: records, config: DiarizationConfig())
        #expect(result.speakerCount <= 2, "\(result.speakerCount) speakers")
    }

    // MARK: Cost

    /// The clustering also runs every 45 s during a live recording, so its cost on realistic data matters: 2 to 3
    /// embedded voices per window, voices that spread (noise 0.03), and a voice that the segmentation often opens
    /// twice in one window (a cluster with same-window conflicts, which keeps the over-merge guard busy).
    @Test func clusteringAnHourWithSeveralVoicesPerWindowAndAConflictingClusterStaysQuick() {
        #if DEBUG
        let windows = 450         // debug builds are about 40 times slower; the bound below is scaled the same way
        let budget = Duration.seconds(60)
        #else
        let windows = 1_800
        let budget = Duration.seconds(8)
        #endif
        let c = centres(6, seed: 90)
        let plan: [[Int]] = (0..<windows).map { w in
            let p = (w / 20) % 6, q = (p + 1) % 6
            var speakers = [p, q]
            if w % 5 < 3 { speakers.append(p) }
            return speakers
        }
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        var result: FinalClusterer.Result!
        let elapsed = Duration.seconds(cpuSeconds { result = FinalClusterer.cluster(records: records, config: DiarizationConfig()) })
        #expect(result.speakerCount >= 6 && result.speakerCount <= 8, "\(result.speakerCount) speakers")
        #expect(elapsed < budget, "clustering \(result.embeddingCount) embeddings took \(elapsed)")
    }

    // MARK: Provisional labels while re-clustering

    @Test func aReaderAlwaysGetsAnAnswerWhileTheOwnerReclusters() async throws {
        var config = DiarizationConfig()
        config.liveReclusterSeconds = 2     // re-cluster after every window
        let session = DiarizationSession(analyzer: ScriptedAnalyzer(), config: config, maxCatchUpWindows: 1_000)
        session.append([Float](repeating: 0.1, count: 16_000 * 120), at: 0)
        for _ in 0..<8 { try session.processNext() }          // windows 0...7 cover the time asked below
        let misses = Misses()
        let stop = Misses()
        let reader = Thread {
            while stop.count == 0 {
                if session.provisionalLabel(start: 6, end: 9) == nil { misses.add() }
            }
        }
        reader.start()
        while try session.processNext() != nil {}
        stop.add()
        while !reader.isFinished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(misses.count == 0, "the answer never goes missing because a re-clustering is running")
    }

    // MARK: An abandoned recording

    @Test func aCancelledDiarizerHandsNothingToTheSink() async throws {
        let gate = DispatchSemaphore(value: 0)
        let analyzer = ScriptedAnalyzer(gate: gate)
        let received = Misses()
        let diarizer = Diarizer(makeAnalyzer: { analyzer }, windowSink: { _ in received.add() })
        let format = ChunkMaker.format()
        for i in 0..<400 {
            diarizer.push(ChunkMaker.chunk(format, from: i * 1_600, frames: 1_600, value: { _ in 0.1 }), startFrame: AVAudioFramePosition(i * 1_600))
        }
        analyzer.waitUntilEntered()      // the first window is being analysed
        diarizer.cancel()
        for _ in 0..<40 { gate.signal() }
        try await Task.sleep(for: .milliseconds(400))
        #expect(received.count == 0, "nothing is published after cancel()")
        #expect(analyzer.analysed <= 1, "and no further window is analysed")
        #expect(await diarizer.finish() == nil)
    }
}

/// A counter that threads can bump.
private final class Misses: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
