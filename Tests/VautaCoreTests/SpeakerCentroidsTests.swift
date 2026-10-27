// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Speaker centroids")
struct SpeakerCentroidsTests {
    private func record(_ embeddings: [[Float]?]) -> WindowRecord {
        WindowRecord(startSample: 0, classes: [], embeddings: embeddings, usableSeconds: embeddings.map { $0 == nil ? 0 : 2 })
    }

    @Test func centroidIsTheNormalisedMeanOfTheSpeakersEmbeddings() {
        let records = [record([[1, 0], [0, 1], nil]), record([[0, 1], nil, nil])]
        let mapping = [[0, 1, -1], [0, -1, -1]]
        let centroids = SpeakerCentroids.compute(records: records, mapping: mapping)
        #expect(centroids.map(\.speaker) == [0, 1])
        #expect(centroids[0].embeddingCount == 2)
        #expect(centroids[0].usableSeconds == 4)
        let s = Float(1 / 2.0.squareRoot())
        #expect(abs(centroids[0].vector[0] - s) < 1e-6 && abs(centroids[0].vector[1] - s) < 1e-6)
        #expect(centroids[1].vector == [0, 1])
    }

    @Test func realSpeechIsTheSumOfWindowSecondsDividedByHowManyWindowsCoverEachSecond() {
        // 10 s windows every 2 s: five windows cover each second of speech, so 5 windows of 10 usable seconds are 10 s of speech
        let records = (0..<5).map { _ in WindowRecord(startSample: 0, classes: [], embeddings: [[1, 0]], usableSeconds: [10]) }
        let c = SpeakerCentroids.compute(records: records, mapping: Array(repeating: [0], count: 5))[0]
        #expect(c.usableSeconds == 50 && c.speechSeconds == 10)
        #expect(!c.isCleanForVoice(), "10 s of speech is below the 30 s gate even though the windows add up to 50")
        let long = (0..<20).map { _ in WindowRecord(startSample: 0, classes: [], embeddings: [[1, 0]], usableSeconds: [10]) }
        #expect(SpeakerCentroids.compute(records: long, mapping: Array(repeating: [0], count: 20))[0].isCleanForVoice(), "40 s of speech passes")
    }

    @Test func overlapShareIsTheTimeAnotherSpeakerAlsoTalks() {
        let turns = [SpeakerTurn(start: 0, end: 10, speaker: 0), SpeakerTurn(start: 8, end: 12, speaker: 1),
                     SpeakerTurn(start: 9, end: 11, speaker: 2), SpeakerTurn(start: 20, end: 30, speaker: 0)]
        let shares = SpeakerCentroids.overlapShares(turns)
        #expect(abs(shares[0]! - 0.1) < 1e-9, "2 s of 20 s are shared, counted once although two speakers cut it")
        #expect(abs(shares[1]! - 0.75) < 1e-9 && abs(shares[2]! - 1.0) < 1e-9)
    }

    @Test func spreadIsHowCloseTheWindowsAreToTheirCentroid() {
        let tight = [record([[1, 0.01], [1, -0.01]])]
        let loose = [record([[1, 0], [0, 1]])]
        #expect(SpeakerCentroids.compute(records: tight, mapping: [[0, 0]])[0].spread > 0.99)
        #expect(SpeakerCentroids.compute(records: loose, mapping: [[0, 0]])[0].spread < 0.75, "two different voices in one cluster")
    }

    @Test func cosineOfUnitVectorsAndMismatchedSizes() {
        #expect(abs(SpeakerCentroids.cosine([1, 0], [1, 0]) - 1) < 1e-6)
        #expect(SpeakerCentroids.cosine([1, 0], [1, 0, 0]) == -1)
    }

    @Test func descriptionNeverShowsTheVector() {
        let c = SpeakerCentroid(speaker: 0, embeddingCount: 1, usableSeconds: 2, vector: [0.123456, 0.654321])
        #expect(!"\(c)".contains("0.1234") && !String(reflecting: c).contains("0.6543"))
    }
}
