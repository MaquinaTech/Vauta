// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The Accelerate fbank against the NumPy reference, and the small pure pieces in front of the networks.
@Suite("Diarization front end")
struct DiarizationFrontEndTests {
    @Test func fbankMatchesTheNumPyReference() throws {
        let clip = try DiarizationFixtures.clip()
        let reference = try DiarizationFixtures.reference()
        let expected = try DiarizationFixtures.referenceFbank(reference)
        let actual = Fbank().compute(DiarizationFixtures.window(clip, at: 0))
        #expect(reference.fbank.frames == SegmentationGeometry.fbankFrames)
        #expect(actual.count == expected.count)
        let differences = zip(actual, expected).map { abs($0 - $1) }
        let mean = differences.reduce(0, +) / Float(differences.count)
        // the reference is stored in steps of 0.001; Float32 FFT against a Float64 one adds a little more
        #expect(mean < 0.002, "mean absolute difference \(mean)")
        #expect(differences.max()! < 0.05, "largest difference \(differences.max()!)")
    }

    @Test func fbankFrameCountFollowsKaldiSnipEdges() {
        #expect(Fbank.frameCount(samples: 160_000) == 998)
        #expect(Fbank.frameCount(samples: 400) == 1)
        #expect(Fbank.frameCount(samples: 399) == 0)
        #expect(Fbank().compute([Float](repeating: 0, count: 399)).isEmpty)
        #expect(Fbank().compute([Float](repeating: 0.1, count: 560)).count == 2 * Fbank.melBins)
    }

    @Test func fbankOfSilenceIsTheFloorAndOfANoiseIsFinite() {
        let silence = Fbank().compute([Float](repeating: 0, count: 1_600))
        #expect(silence.allSatisfy { $0 == logf(Float.ulpOfOne) })
        var random = TestRandom(seed: 3)
        let noise = Fbank().compute((0..<16_000).map { _ in 0.1 * random.gaussian() })
        #expect(noise.allSatisfy { $0.isFinite })
    }

    @Test func logSoftmaxIsNormalisedAndStable() {
        let scores = Powerset.logSoftmax([10, 11, 9, 0, -10, 5, 5] + [Float](repeating: 0, count: 7), frames: 2)
        for t in 0..<2 {
            let sum = (0..<7).reduce(0.0) { $0 + exp(Double(scores[t * 7 + $1])) }
            #expect(abs(sum - 1) < 1e-6)
        }
        #expect(Powerset.argmaxClasses(scores, frames: 2) == [1, 0])
        // huge logits must not overflow
        let huge = Powerset.logSoftmax([1_000, 1_001, 999, 0, -1_000, 5, 5], frames: 1)
        #expect(huge.allSatisfy { $0.isFinite } && huge[1] > huge[0])
    }

    @Test func masksDropOverlapAndFallBackWhenTooShort() {
        // frames 0..199 speaker 0 alone, 200..399 speakers 0+1, 400..588 speaker 2 alone for 0.5 s then none
        var classes = [UInt8](repeating: 0, count: SegmentationGeometry.frames)
        for t in 0..<200 { classes[t] = 1 }
        for t in 200..<400 { classes[t] = 4 }
        for t in 400..<430 { classes[t] = 3 }
        let (masks, seconds) = MaskBuilder.masks(classes: classes, excludeOverlap: true, minSeconds: 1)
        #expect(masks[0].reduce(0, +) == 200)                      // alone frames only
        #expect(masks[1].reduce(0, +) == 200 && masks[1][250] == 1) // speaker 1 is never alone: all active frames
        #expect(masks[2].reduce(0, +) == 30)                       // too short either way
        #expect(abs(seconds[0] - 200 * Float(SegmentationGeometry.frameStepSeconds)) < 1e-4)
        let (all, _) = MaskBuilder.masks(classes: classes, excludeOverlap: false, minSeconds: 1)
        #expect(all[0].reduce(0, +) == 400)
    }

    @Test func powersetClassesNameTheirSpeakers() {
        #expect(Powerset.speakerMask == [0, 1, 2, 4, 3, 5, 6])
        #expect(Powerset.activeCount == [0, 1, 1, 1, 2, 2, 2])
    }

    @Test func configScalesWithTheStep() {
        var config = DiarizationConfig()
        #expect(config.minClusterSize == 10)
        #expect(config.stepSamples == 32_000)
        #expect(config.liveReclusterWindows == 23)
        config.stepSeconds = 1
        #expect(config.minClusterSize == 20)
        #expect(config.stepSamples == 16_000)
    }

    @Test func foldSizeScalesWithTheMeetingLength() {
        let config = DiarizationConfig()
        #expect(config.foldMinSize(durationSeconds: 300) == 6)    // 12 s floor at the 2 s step
        #expect(config.foldMinSize(durationSeconds: 1_200) == 9)  // 1.5 % of 20 minutes = 18 s
        #expect(config.foldMinSize(durationSeconds: 3_600) == 15) // 30 s ceiling
        #expect(config.foldMinSize(durationSeconds: 7_200) == 15) // the ceiling holds for long meetings
        var fixed = config
        fixed.foldDurationShare = 0
        #expect(fixed.foldMinSize(durationSeconds: 3_600) == fixed.minClusterSize)
    }

    @Test func outputDefaultsMergeShortPausesAndUseUniformWeights() {
        let config = DiarizationConfig()
        #expect(config.minGapSeconds == 0.5)
        #expect(config.hammingFrameWeights == false)
        #expect(config.foldCeilingSeconds == 30)
    }

    @Test func theFoldUsesTheRealLengthOfTheRecording() {
        // 600 windows at the 2 s step: 1,198 s of starts plus the 10 s of the last window
        let records = (0..<600).map { WindowRecord(startSample: $0 * 32_000, classes: [], embeddings: [nil, nil, nil], usableSeconds: [0, 0, 0]) }
        #expect(FinalClusterer.durationSeconds(records: records) == 1_208)
        #expect(DiarizationConfig().foldMinSize(durationSeconds: 1_208) == 9, "1.5 % of 20 minutes, 18 s, at the 2 s step")
        #expect(FinalClusterer.durationSeconds(records: records, totalSamples: 16_000 * 1_300) == 1_300, "the caller's own length wins")
    }

    @Test func uniformWeightsAndHammingWeightsDrawDifferentBoundaries() {
        // Two windows 2 s apart disagree about frames 300...419: the first still hears speaker 0, the second already speaker 1.
        let frames = SegmentationGeometry.frames
        let shift = 32_000 / SegmentationGeometry.frameStepSamples
        var first = [UInt8](repeating: 1, count: frames)    // speaker 0 ...
        for t in 420..<frames { first[t] = 2 }              // ... then speaker 1
        var second = [UInt8](repeating: 2, count: frames)
        for t in 0..<(300 - shift) { second[t] = 1 }
        let records = [WindowRecord(startSample: 0, classes: first, embeddings: [nil, nil, nil], usableSeconds: [5, 5, 0]),
                       WindowRecord(startSample: 32_000, classes: second, embeddings: [nil, nil, nil], usableSeconds: [5, 5, 0])]
        func firstSpeakerEnd(hamming: Bool) -> Double? {
            var config = DiarizationConfig()
            config.hammingFrameWeights = hamming
            let turns = Reconstruction.finalTurns(records: records, mapping: [[0, 1, -1], [0, 1, -1]], speakerCount: 2, totalSamples: 192_000, config: config)
            return turns.filter { $0.speaker == 0 }.map(\.end).max()
        }
        let weighted = firstSpeakerEnd(hamming: true), uniform = firstSpeakerEnd(hamming: false)
        #expect(weighted != nil && uniform != nil)
        #expect(abs((weighted ?? 0) - (uniform ?? 0)) > 0.5, "weighted \(weighted ?? -1) s, uniform \(uniform ?? -1) s")
    }

    @Test func pausesUnderTheGapAreOneTurn() {
        let step = SegmentationGeometry.frameStepSeconds
        let frames = Int((2.0 / step).rounded())
        let pause = Int((0.3 / step).rounded())      // 0.3 s: merged at 0.5 s, split at 0.1 s
        let longPause = Int((0.9 / step).rounded())  // 0.9 s: always split
        var flags = [Bool](repeating: true, count: frames)
        flags += [Bool](repeating: false, count: pause)
        flags += [Bool](repeating: true, count: frames)
        flags += [Bool](repeating: false, count: longPause)
        flags += [Bool](repeating: true, count: frames)
        let merged = Reconstruction.turns(from: [flags], config: DiarizationConfig())
        #expect(merged.count == 2)
        var old = DiarizationConfig()
        old.minGapSeconds = 0.1
        #expect(Reconstruction.turns(from: [flags], config: old).count == 3)
    }

    @Test func recordsNeverPrintEmbeddings() {
        let record = WindowRecord(startSample: 0, classes: [], embeddings: [[0.123_456], nil, nil], usableSeconds: [1, 0, 0])
        #expect(!"\(record)".contains("0.123"))
        #expect(!String(reflecting: record).contains("0.123"))
    }
}
