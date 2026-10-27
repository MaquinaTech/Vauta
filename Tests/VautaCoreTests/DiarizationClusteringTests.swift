// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Diarization clustering")
struct DiarizationClusteringTests {
    private func centres(_ count: Int, seed: UInt64 = 11) -> [[Float]] {
        var random = TestRandom(seed: seed)
        return (0..<count).map { _ in random.unitVector() }
    }

    // MARK: - Agglomerative clustering

    @Test(arguments: ["0.5", "0.7", "0.9", "1.0", "1.1", "1.25"])
    func agglomerativeClusteringMatchesScipy(cut: String) throws {
        let (vectors, fixture) = try DiarizationFixtures.ahcVectors()
        let expected = try #require(fixture.labels[cut])
        let actual = AgglomerativeClustering.cluster(vectors: vectors, threshold: Float(cut)!)
        #expect(SyntheticRecords.samePartition(actual, expected), "cut \(cut): \(Set(actual).count) clusters against scipy's \(Set(expected).count)")
    }

    @Test func weightedPointsClusterLikeTheirExpansion() {
        var random = TestRandom(seed: 5)
        let base = centres(3, seed: 5)
        let points = (0..<9).map { random.around(base[$0 % 3], noise: 0.03) }
        let sizes: [Float] = [4, 1, 3, 2, 5, 1, 1, 2, 6]
        var expanded: [[Float]] = [], owner: [Int] = []
        for (i, size) in sizes.enumerated() { for _ in 0..<Int(size) { expanded.append(points[i]); owner.append(i) } }
        for cut in [Float(0.3), 0.9, 1.3] {
            let weighted = AgglomerativeClustering.cluster(vectors: points, sizes: sizes, threshold: cut)
            let plain = AgglomerativeClustering.cluster(vectors: expanded, threshold: cut)
            #expect(SyntheticRecords.samePartition(owner.map { weighted[$0] }, plain), "cut \(cut)")
        }
    }

    @Test func establishedClustersMergeOnlyBelowTheMargin() {
        // two tight groups of 40 whose centroids are 0.72 apart
        var random = TestRandom(seed: 8)
        let a = random.unitVector()
        let b = VectorMath.normalised(zip(a, random.unitVector()).map { 0.741 * $0 + 0.671 * $1 })   // distance to a about 0.72
        let group = (0..<40).map { _ in random.around(a, noise: 0.004) } + (0..<40).map { _ in random.around(b, noise: 0.004) }
        // the height at which the plain dendrogram joins the groups
        let height = stride(from: Float(0.5), through: 1.2, by: 0.01).first { Set(AgglomerativeClustering.cluster(vectors: group, threshold: $0)).count == 1 }!
        let cut = height + 0.03
        // a plain cut just above that height merges them; established groups (>= 30 points) need a 0.1 margin
        #expect(Set(AgglomerativeClustering.cluster(vectors: group, threshold: cut)).count == 1)
        #expect(Set(AgglomerativeClustering.cluster(vectors: group, threshold: cut, establishedSize: 30, establishedMargin: 0.1)).count == 2)
        // within the margin they still merge, and groups below the size are not held back
        #expect(Set(AgglomerativeClustering.cluster(vectors: group, threshold: cut, establishedSize: 30, establishedMargin: 0.01)).count == 1)
        #expect(Set(AgglomerativeClustering.cluster(vectors: group, threshold: cut, establishedSize: 50, establishedMargin: 0.1)).count == 1)
    }

    @Test func tinyInputs() {
        #expect(AgglomerativeClustering.cluster(vectors: [], threshold: 0.7).isEmpty)
        #expect(AgglomerativeClustering.cluster(vectors: [[1, 0]], threshold: 0.7) == [0])
        #expect(AgglomerativeClustering.cluster(vectors: [[1, 0], [0, 1]], threshold: 0.7) == [0, 1])
        #expect(AgglomerativeClustering.cluster(vectors: [[1, 0], [0, 1]], threshold: 1.5) == [0, 0])
    }

    // MARK: - Final clustering

    @Test func finalClusteringRecoversSpeakersAndNumbersThemByAppearance() {
        let c = centres(3)
        // speaker 2 talks first, then 0, then 1; windows hold one or two speakers
        let plan: [[Int]] = Array(repeating: [2], count: 14) + Array(repeating: [0, 2], count: 8) + Array(repeating: [0], count: 14)
            + Array(repeating: [1, 0], count: 10) + Array(repeating: [1], count: 14)
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        let result = FinalClusterer.cluster(records: records, config: DiarizationConfig())
        #expect(result.speakerCount == 3)
        // numbering by first appearance: centre 2 -> 0, centre 0 -> 1, centre 1 -> 2
        let numbering = [2: 0, 0: 1, 1: 2]
        for (w, speakers) in plan.enumerated() {
            for (local, centre) in speakers.enumerated() { #expect(result.mapping[w][local] == numbering[centre]) }
            for local in speakers.count..<3 { #expect(result.mapping[w][local] == -1) }
        }
    }

    @Test func tinyClustersJoinTheNearestLargeOne() {
        let c = centres(3)
        // a third voice appears in 4 windows only (< 10 embeddings) and sits near centre 0
        var close = TestRandom(seed: 99)
        let near = close.around(c[0], noise: 0.05)
        let plan: [[Int]] = Array(repeating: [0], count: 20) + Array(repeating: [1], count: 20) + Array(repeating: [2], count: 4)
        var records = SyntheticRecords.records(plan: plan, centres: [c[0], c[1], near], noise: 0.0)
        for w in 40..<44 { records[w].embeddings[0] = close.around(near, noise: 0.01) }
        // make the stray voice far enough from centre 0 that the dendrogram keeps it apart
        let strays = c[2]
        for w in 40..<44 { records[w].embeddings[0] = close.around(strays, noise: 0.01) }
        let result = FinalClusterer.cluster(records: records, config: DiarizationConfig())
        #expect(result.speakerCount == 2)
        #expect((40..<44).allSatisfy { result.mapping[$0][0] >= 0 })

        var config = DiarizationConfig()
        config.foldDurationShare = 0   // the fixed fold applies
        config.minClusterSeconds = 4   // 2 embeddings: the stray voice is a speaker
        #expect(FinalClusterer.cluster(records: records, config: config).speakerCount == 3)
        config = DiarizationConfig()
        config.foldFloorSeconds = 4    // the scaled fold with a 4 s floor (88 s meeting: 1.3 s -> floor)
        #expect(FinalClusterer.cluster(records: records, config: config).speakerCount == 3)
    }

    @Test func theFoldCeilingKeepsAGuestInALongMeeting() {
        let c = centres(3)
        // 400 windows (800 s) with a guest of 16 windows (32 s); the share is raised so that the scaled fold would reach
        // 120 s, as 1.5 % does for a meeting of more than two hours (a real hour-long input makes the debug build take minutes)
        let plan: [[Int]] = Array(repeating: [0], count: 190) + Array(repeating: [2], count: 16) + Array(repeating: [1], count: 194)
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        var config = DiarizationConfig()
        config.foldDurationShare = 0.15
        #expect(config.foldMinSize(durationSeconds: 800) == 15)   // 120 s clamped to the 30 s ceiling
        #expect(FinalClusterer.cluster(records: records, config: config).speakerCount == 3)
        config.foldCeilingSeconds = 90
        #expect(FinalClusterer.cluster(records: records, config: config).speakerCount == 2, "without the ceiling the guest is folded away")
    }

    @Test func aShortMeetingKeepsItsSmallClusters() {
        let plan: [[Int]] = Array(repeating: [0], count: 4) + Array(repeating: [1], count: 3)
        let records = SyntheticRecords.records(plan: plan, centres: centres(2), noise: 0.03)
        #expect(FinalClusterer.cluster(records: records, config: DiarizationConfig()).speakerCount == 2)
    }

    @Test func eachWindowKeepsItsLocalSpeakersApart() {
        let c = centres(2)
        let plan: [[Int]] = Array(repeating: [0, 1], count: 24) + Array(repeating: [1, 0], count: 24)
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        let result = FinalClusterer.cluster(records: records, config: DiarizationConfig())
        #expect(result.speakerCount == 2)
        for row in result.mapping { #expect(row[0] != row[1]) }
    }

    @Test func noEmbeddingsNoSpeakers() {
        let record = WindowRecord(startSample: 0, classes: [UInt8](repeating: 0, count: 589), embeddings: [nil, nil, nil], usableSeconds: [0, 0, 0])
        let result = FinalClusterer.cluster(records: [record, record], config: DiarizationConfig())
        #expect(result.speakerCount == 0 && result.mapping == [[-1, -1, -1], [-1, -1, -1]])
        #expect(FinalClusterer.cluster(records: [], config: DiarizationConfig()).speakerCount == 0)
    }

    @Test func twoStageClusteringMatchesOneStage() {
        let c = centres(4, seed: 21)
        var plan: [[Int]] = []
        for block in 0..<12 { plan += Array(repeating: [block % 4], count: 40) }
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        let vectors = records.compactMap { $0.embeddings[0] }
        var direct = DiarizationConfig()
        direct.maxDirectEmbeddings = 10_000
        var staged = DiarizationConfig()
        staged.maxDirectEmbeddings = 100
        staged.stageChunkSize = 130
        let one = FinalClusterer.agglomerate(vectors, config: direct)
        let two = FinalClusterer.agglomerate(vectors, config: staged)
        #expect(Set(one).count == 4)
        #expect(SyntheticRecords.samePartition(one, two))
        #expect(FinalClusterer.cluster(records: records, config: staged).speakerCount == 4)
    }

    // MARK: - Over-merge guard

    /// Two different voices that sit closer together than the cut: the dendrogram merges them, but they speak in the
    /// same windows, so the segmentation network itself says they are two people.
    private func closeVoices() -> [WindowRecord] {
        var random = TestRandom(seed: 41)
        let a = random.unitVector()
        let b = VectorMath.normalised(zip(a, random.unitVector()).map { 0.9 * $0 + 0.5 * $1 })   // distance to a about 0.6
        let others = centres(1, seed: 77)
        let plan: [[Int]] = Array(repeating: [0, 1], count: 30) + Array(repeating: [2], count: 30)
        return SyntheticRecords.records(plan: plan, centres: [a, b, others[0]], noise: 0.012)
    }

    @Test func overMergedSpeakersAreSplitAgain() {
        let records = closeVoices()
        var off = DiarizationConfig()
        off.maxSameWindowConflict = 1
        off.reassignToCentroids = false
        #expect(FinalClusterer.cluster(records: records, config: off).speakerCount == 2, "without the guard the two close voices are one speaker")
        var on = off
        on.maxSameWindowConflict = 0.25
        let result = FinalClusterer.cluster(records: records, config: on)
        #expect(result.speakerCount == 3)
        for w in 0..<30 { #expect(result.mapping[w][0] != result.mapping[w][1]) }
    }

    @Test func overMergedSpeakersAreSplitAlsoWhenTheClusterIsTooBigForOneMatrix() {
        let records = closeVoices()
        var direct = DiarizationConfig()
        direct.maxSameWindowConflict = 0.25
        direct.reassignToCentroids = false
        var staged = direct
        staged.maxDirectEmbeddings = 50     // the 60-member merged cluster takes the staged path
        staged.stageChunkSize = 30
        let one = FinalClusterer.cluster(records: records, config: direct)
        let two = FinalClusterer.cluster(records: records, config: staged)
        #expect(two.speakerCount == 3)
        for w in 0..<30 { #expect(two.mapping[w][0] != two.mapping[w][1]) }
        #expect(SyntheticRecords.samePartition(one.mapping.joined().map { $0 }, two.mapping.joined().map { $0 }))
    }

    @Test func theGuardLeavesCorrectClustersAlone() {
        let c = centres(3)
        let plan: [[Int]] = Array(repeating: [0, 1], count: 20) + Array(repeating: [1, 2], count: 20) + Array(repeating: [2, 0], count: 20)
        let records = SyntheticRecords.records(plan: plan, centres: c, noise: 0.03)
        var off = DiarizationConfig()
        off.maxSameWindowConflict = 1
        #expect(FinalClusterer.cluster(records: records, config: off).mapping == FinalClusterer.cluster(records: records, config: DiarizationConfig()).mapping)
    }

    @Test func conflictRatioCountsWindowsWithTwoMembers() {
        let refs: [(window: Int, speaker: Int)] = [(0, 0), (0, 1), (1, 0), (2, 0), (2, 1), (3, 2)]
        #expect(FinalClusterer.conflictRatio(of: [0, 1, 2, 3, 4, 5], refs: refs) == 0.5)
        #expect(FinalClusterer.conflictRatio(of: [0, 2, 5], refs: refs) == 0)
        #expect(FinalClusterer.conflictRatio(of: [], refs: refs) == 0)
    }

    // MARK: - Hungarian

    @Test func hungarianFindsTheBestAssignment() {
        var random = TestRandom(seed: 17)
        for (rows, columns) in [(1, 1), (2, 2), (3, 3), (3, 5), (5, 3), (6, 6), (4, 7)] {
            let weights = (0..<rows).map { _ in (0..<columns).map { _ in Int(random.next() % 20) } }
            let chosen = Hungarian.maximize(weights)
            var total = 0
            for (row, column) in chosen.enumerated() { if let column { total += weights[row][column] } }
            #expect(Set(chosen.compactMap { $0 }).count == chosen.compactMap { $0 }.count, "columns are used once")
            #expect(total == bruteForce(weights), "\(rows)x\(columns)")
        }
    }

    @Test func hungarianLeavesZeroWeightsUnassigned() {
        #expect(Hungarian.maximize([[0, 0], [0, 5]]) == [nil, 1])
        #expect(Hungarian.maximize([]) == [])
        #expect(Hungarian.maximize([[], []]) == [nil, nil])
    }

    private func bruteForce(_ weights: [[Int]]) -> Int {
        let rows = weights.count, columns = weights[0].count
        func best(_ row: Int, _ used: Set<Int>) -> Int {
            guard row < rows else { return 0 }
            var top = best(row + 1, used)   // the row may stay unassigned
            for c in 0..<columns where !used.contains(c) { top = max(top, weights[row][c] + best(row + 1, used.union([c]))) }
            return top
        }
        return best(0, [])
    }
}
