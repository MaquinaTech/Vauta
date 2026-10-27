// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The pure part of voice recognition: the three bands, the templates, one person per speaker, and the Me/Others split
/// of an imported recording.
@Suite("Voice matching")
struct VoiceMatcherTests {
    /// A unit vector whose cosine with `base` is `cosine`.
    static func vector(cosine: Float, from base: [Float], seed: UInt64 = 99) -> [Float] {
        var random = TestRandom(seed: seed)
        var other = random.unitVector()
        let projection = VectorMath.dot(other, base)
        other = VectorMath.normalised(zip(other, base).map { $0 - projection * $1 })
        let sine = (1 - cosine * cosine).squareRoot()
        return VectorMath.normalised(zip(base, other).map { cosine * $0 + sine * $1 })
    }

    static func centroid(_ speaker: Int, _ vector: [Float], seconds: Double = 120, overlap: Double = 0, spread: Float = 0.9) -> SpeakerCentroid {
        SpeakerCentroid(speaker: speaker, embeddingCount: 50, usableSeconds: seconds * 5, speechSeconds: seconds, overlapShare: overlap, spread: spread, vector: vector)
    }

    static func profile(_ id: Int64, entity: Int64, _ vector: [Float]) -> VoiceProfileEmbedding {
        VoiceProfileEmbedding(profileID: id, entityID: entity, embedding: VoiceMatcher.encode(vector))
    }

    @Test func theThresholdsAreTheCalibratedOnes() {
        #expect(VoiceProfileThresholds.suggest == 0.70, "one cut-off: a saved voice only suggests")
        #expect(VoiceProfileThresholds.minimumSpeechSeconds == 30)
        #expect(VoiceProfileThresholds.unusedMonths == 12)
    }

    @Test func aSpeakerIsOnlyEverSuggested() {
        var random = TestRandom(seed: 5)
        let ana = random.unitVector()
        let templates = VoiceMatcher.templates(from: [Self.profile(1, entity: 10, ana)])
        for cosine in [Float(0.99), 0.90, 0.80, 0.75, 0.71] {
            let found = VoiceMatcher.match([Self.centroid(0, Self.vector(cosine: cosine, from: ana))], against: templates)
            #expect(found.count == 1 && found[0].entityID == 10 && found[0].profileIDs == [1], "cosine \(cosine) is a suggestion, however high")
            #expect(abs(found[0].cosine - cosine) < 0.01)
        }
        #expect(VoiceMatcher.match([Self.centroid(0, Self.vector(cosine: 0.70, from: ana))], against: templates).count == 1, "the threshold itself suggests")
        #expect(VoiceMatcher.match([Self.centroid(0, Self.vector(cosine: 0.69, from: ana))], against: templates).isEmpty, "below the threshold nothing is said")
        #expect(VoiceMatcher.match([Self.centroid(0, Self.vector(cosine: 0.60, from: ana))], against: templates).isEmpty)
    }

    @Test func aSpeakerWithTooLittleCleanSpeechIsNeverMatched() {
        var random = TestRandom(seed: 5)
        let ana = random.unitVector()
        let templates = VoiceMatcher.templates(from: [Self.profile(1, entity: 10, ana)])
        #expect(VoiceMatcher.match([Self.centroid(0, ana, seconds: 29.9)], against: templates).isEmpty)
        #expect(VoiceMatcher.match([Self.centroid(0, ana, seconds: 30)], against: templates).count == 1)
    }

    @Test func theGateCountsRealSpeechCrosstalkAndSpreadNotWindows() {
        var random = TestRandom(seed: 11)
        let ana = random.unitVector()
        let templates = VoiceMatcher.templates(from: [Self.profile(1, entity: 10, ana)])
        // 10 s of real speech: windows of 10 s every 2 s count it five times, so the sum is 50 "usable" seconds
        let tenSeconds = SpeakerCentroid(speaker: 0, embeddingCount: 5, usableSeconds: 50, speechSeconds: 10, vector: ana)
        #expect(tenSeconds.usableSeconds >= 30 && !tenSeconds.isCleanForVoice(), "50 summed seconds are 10 real seconds: not enough")
        #expect(VoiceMatcher.match([tenSeconds], against: templates).isEmpty)
        #expect(VoiceMatcher.match([Self.centroid(0, ana, overlap: 0.41)], against: templates).isEmpty, "too much crosstalk")
        #expect(VoiceMatcher.match([Self.centroid(0, ana, overlap: 0.40)], against: templates).count == 1)
        #expect(VoiceMatcher.match([Self.centroid(0, ana, spread: 0.59)], against: templates).isEmpty, "a loose cluster may hold two voices")
        #expect(VoiceMatcher.match([Self.centroid(0, ana, spread: 0.60)], against: templates).count == 1)
    }

    @Test func aPersonNamesAtMostOneSpeakerAndTheCloserOneWins() {
        var random = TestRandom(seed: 6)
        let ana = random.unitVector(), bea = random.unitVector()
        let templates = VoiceMatcher.templates(from: [Self.profile(1, entity: 10, ana), Self.profile(2, entity: 11, bea)])
        let close = Self.vector(cosine: 0.95, from: ana), far = Self.vector(cosine: 0.85, from: ana, seed: 3)
        let found = VoiceMatcher.match([Self.centroid(0, far), Self.centroid(1, close)], against: templates)
        #expect(found.map(\.speaker) == [1] && found[0].entityID == 10, "the other speaker is not Ana too: it stays Speaker k")
    }

    @Test func theTemplateIsTheNormalisedMeanOfThePersonsFingerprints() {
        var random = TestRandom(seed: 7)
        let a = random.unitVector(), b = random.unitVector()
        let templates = VoiceMatcher.templates(from: [Self.profile(1, entity: 10, a), Self.profile(2, entity: 10, b)])
        #expect(templates.count == 1 && templates[0].profileIDs == [1, 2])
        let mean = VectorMath.normalised(zip(a, b).map { $0 + $1 })
        #expect(SpeakerCentroids.cosine(templates[0].vector, mean) > 0.9999)
        #expect(VoiceMatcher.templates(from: [Self.profile(1, entity: 10, a)], excluding: [10]).isEmpty)
    }

    @Test func aDamagedFingerprintIsIgnoredAndVectorsRoundTrip() {
        var random = TestRandom(seed: 8)
        let v = random.unitVector()
        #expect(VoiceMatcher.decode(VoiceMatcher.encode(v)) == v)
        #expect(VoiceMatcher.decode(Data(repeating: 1, count: 12)) == nil)
        #expect(VoiceMatcher.decode(VoiceMatcher.encode([Float](repeating: .nan, count: 256))) == nil)
        let templates = VoiceMatcher.templates(from: [VoiceProfileEmbedding(profileID: 1, entityID: 10, embedding: Data(repeating: 9, count: 8))])
        #expect(templates.isEmpty)
    }

    @Test func thereIsNoRecognitionWithoutProfiles() {
        var random = TestRandom(seed: 9)
        #expect(VoiceMatcher.match([Self.centroid(0, random.unitVector())], against: []).isEmpty)
    }

    @Test func voiceTypesNeverPrintTheirVectors() {
        var random = TestRandom(seed: 10)
        let v = random.unitVector()
        let draft = SpeakerVoiceDraft(channel: .others, ordinal: 1, modelID: "m", embedding: VoiceMatcher.encode(v))
        let template = VoiceMatcher.templates(from: [Self.profile(1, entity: 2, v)])
        let text = "\(draft) \(String(reflecting: draft)) \(Self.profile(1, entity: 2, v)) \(String(reflecting: Self.profile(1, entity: 2, v))) \(template) \(String(reflecting: template))"
        #expect(!text.contains("0.") && !text.contains("-0"))
    }
}
