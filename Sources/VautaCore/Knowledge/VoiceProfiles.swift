// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The cut-off of voice recognition, as cosine similarity of L2-normalised 256-dimension embeddings. It belongs
/// to ONE embedding model (`DiarizationModels.embeddingModelID`): another model needs its own calibration, and its
/// profiles are unusable until then (`MeetingStore.voiceProfileEmbeddings(modelID:)` never returns them).
///
/// Saved voices only SUGGEST ("Is this Ana?"); they never name a speaker (by design, since 2026-10-10). On remote audio
/// (what a live recording hears of the other participants) the right person is reached at 0.80 only about 61% to 71% of
/// the time and wrong names reached 2% to 10% with 4 to 32 saved people (docs/ARCHITECTURE.md), too unreliable to
/// show as a name, but fine for a question the user answers with one click. Calibrated on English AMI and VoxConverse
/// with every speaker the app would match, not only the clean ones: with the quality gate below, 1% to 2% of impostor
/// comparisons reach 0.70 (6% to 8% between colleagues of one room; on remote audio about 2.7%, and about 15% between
/// colleagues of one room). Not measured: other languages, phone audio, relatives with similar voices. A template that
/// averages several fingerprints is not calibrated. Treat the cut-off as a starting point, never as a guarantee; the
/// user's own word always wins.
public enum VoiceProfileThresholds {
    /// At or above: "Is this Ana?", a suggestion that is never shown as a name (source `suggested`). Below: "Speaker k".
    /// When two speakers resemble the same person, the closer one gets the suggestion.
    public static let suggest: Float = 0.70
    /// A speaker needs this much real clean speech (seconds of speech, not windows) to be matched or remembered: the
    /// calibration used 30 s of turn speech.
    public static let minimumSpeechSeconds = 30.0
    /// A speaker who shares more than this part of their turn time with another voice is never matched or remembered:
    /// the cluster is probably contaminated by the other voice (measured in docs/ARCHITECTURE.md).
    public static let maximumOverlapShare = 0.40
    /// A speaker whose window embeddings are, on average, less similar than this to their own centroid is never
    /// matched or remembered: the cluster probably holds two voices.
    public static let minimumSpread: Float = 0.60
    /// A voice summary kept for "Remember this voice" is deleted this many days after the meeting was processed.
    public static let keptSummaryDays = 14
    /// A profile that has not matched anybody in this long is proposed for deletion (the user confirms).
    public static let unusedMonths = 12
}

extension SpeakerCentroid {
    /// The speaker's voice is clean enough to be matched with saved voices or to be remembered: enough real speech,
    /// little crosstalk and a tight cluster. Quality is judged only with signals the app has at run time.
    public func isCleanForVoice(minimumSeconds: Double = VoiceProfileThresholds.minimumSpeechSeconds) -> Bool {
        speechSeconds >= minimumSeconds && overlapShare <= VoiceProfileThresholds.maximumOverlapShare
            && spread >= VoiceProfileThresholds.minimumSpread
    }
}

/// One speaker matched with one person: a suggestion.
public struct VoiceMatch: Sendable, Equatable {
    /// 0-based diarization speaker.
    public var speaker: Int
    public var entityID: Int64
    public var cosine: Float
    /// The saved fingerprints of the person that made the template.
    public var profileIDs: [Int64]
}

/// A person's saved voice for comparing: the L2-normalised mean of their fingerprints (the "mean template").
/// Voice data: it prints without the vector.
public struct VoiceTemplate: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var entityID: Int64
    public var vector: [Float]
    public var profileIDs: [Int64]

    public var description: String { "VoiceTemplate(entity: \(entityID), fingerprints: \(profileIDs.count))" }
    public var debugDescription: String { description }
}

/// Matching speakers with saved voices. Pure: it never touches the store.
public enum VoiceMatcher {
    /// Dimension of one embedding.
    public static let dimension = 256

    /// A voice vector as it is stored: little-endian Float32.
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// nil when the data is not a vector of `dimension` finite numbers.
    public static func decode(_ data: Data) -> [Float]? {
        guard data.count == dimension * MemoryLayout<Float>.size else { return nil }
        var vector = [Float](repeating: 0, count: dimension)
        _ = vector.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return vector.allSatisfy(\.isFinite) ? vector : nil
    }

    /// One template per person from their fingerprints. Fingerprints that do not decode are ignored.
    public static func templates(from embeddings: [VoiceProfileEmbedding], excluding excluded: Set<Int64> = []) -> [VoiceTemplate] {
        var sums: [Int64: [Float]] = [:]
        var ids: [Int64: [Int64]] = [:]
        for e in embeddings where !excluded.contains(e.entityID) {
            guard let v = decode(e.embedding) else { continue }
            if sums[e.entityID] == nil { sums[e.entityID] = [Float](repeating: 0, count: dimension) }
            for i in v.indices { sums[e.entityID]![i] += v[i] }
            ids[e.entityID, default: []].append(e.profileID)
        }
        return sums.keys.sorted().map { VoiceTemplate(entityID: $0, vector: VectorMath.normalised(sums[$0]!), profileIDs: ids[$0] ?? []) }
    }

    /// Matches every speaker with enough clean speech against the templates, best first.
    ///
    /// - Each person is suggested for at most one speaker: if two speakers match the same person, the closer keeps the match
    ///   and the other is matched with its next-best person (or none).
    /// - A speaker with less than `minimumSpeechSeconds` of real speech, too much crosstalk or a loose cluster is never matched.
    /// - Only speakers at or above the suggestion threshold are returned.
    public static func match(_ centroids: [SpeakerCentroid], against templates: [VoiceTemplate],
                             minimumSeconds: Double = VoiceProfileThresholds.minimumSpeechSeconds) -> [VoiceMatch] {
        match(vectors: centroids.filter { $0.isCleanForVoice(minimumSeconds: minimumSeconds) }.map { ($0.speaker, $0.vector) }, against: templates)
    }

    /// The same matching for vectors already known to be clean (a stored centroid passed the gate when it was kept).
    public static func match(vectors: [(speaker: Int, vector: [Float])], against templates: [VoiceTemplate]) -> [VoiceMatch] {
        var pairs: [VoiceMatch] = []
        for c in vectors {
            for t in templates {
                let cos = SpeakerCentroids.cosine(c.vector, t.vector)
                if cos >= VoiceProfileThresholds.suggest {
                    pairs.append(VoiceMatch(speaker: c.speaker, entityID: t.entityID, cosine: cos, profileIDs: t.profileIDs))
                }
            }
        }
        pairs.sort { ($0.cosine, -Float($0.speaker)) > ($1.cosine, -Float($1.speaker)) }
        var speakers = Set<Int>(), people = Set<Int64>()
        var out: [VoiceMatch] = []
        for pair in pairs where !speakers.contains(pair.speaker) && !people.contains(pair.entityID) {
            speakers.insert(pair.speaker)
            people.insert(pair.entityID)
            out.append(pair)
        }
        return out
    }
}
