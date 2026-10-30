// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// One speaker of one meeting (`meeting_speakers`).
public struct MeetingSpeaker: Sendable, Identifiable, Hashable {
    /// Who named the speaker: the user, or nobody ("Speaker k"); a saved voice only suggests (`suggested`).
    /// Calendar attendees are suggestions shown by the UI; they are never stored as an assignment.
    /// Nothing names a speaker from what the transcript says.
    public enum Source: String, Sendable, CaseIterable {
        /// Found by the diarizer; not named.
        case auto
        /// The user chose the person. Ground truth: never overwritten.
        case user
        /// A saved voice resembles this person ("Is this Ana?"): `entityID` is only a candidate and is never shown as
        /// a name. Accepting it is a user assignment.
        case suggested
    }

    public let id: Int64
    public let meetingID: Int64
    public let channel: Channel
    /// Numbered by first appearance within its channel (from 1): "Speaker <ordinal>" for Others, "Me" then
    /// "Me <ordinal>" for the user's channel, so no two speakers of a meeting share a default label.
    public let ordinal: Int
    public let entityID: Int64?
    /// The entity's stored name; nil without an entity.
    public let entityName: String?
    /// The entity is the user's own (self) entity.
    public let entityIsSelf: Bool
    public let source: Source
    public let confidence: Double?
    public let talkSeconds: Double

    public init(id: Int64, meetingID: Int64, channel: Channel, ordinal: Int, entityID: Int64? = nil, entityName: String? = nil,
                entityIsSelf: Bool = false, source: Source = .auto, confidence: Double? = nil, talkSeconds: Double = 0) {
        self.id = id
        self.meetingID = meetingID
        self.channel = channel
        self.ordinal = ordinal
        self.entityID = entityID
        self.entityName = entityName
        self.entityIsSelf = entityIsSelf
        self.source = source
        self.confidence = confidence
        self.talkSeconds = talkSeconds
    }

    /// The person's name when the user named the speaker
    /// (the user's own entity shows as "Me" while it keeps its stored name).
    public var name: String? {
        guard source == .user, let entityName else { return nil }
        return MeetingStore.displayName(entityName, isSelf: entityIsSelf)
    }

    /// What to show: the name, else "Me" (first speaker of the user's channel), "Me k", or "Speaker k".
    public var displayName: String {
        name ?? Self.defaultLabel(channel: channel, ordinal: ordinal)
    }

    /// The localized label of an unnamed speaker.
    public static func defaultLabel(channel: Channel, ordinal: Int) -> String {
        if channel == .me && ordinal == 1 { return Channel.me.displayName }
        if channel == .me {
            return String(localized: "Me \(ordinal)", comment: "Unnamed extra speaker on the user's own microphone (a second voice in the room); the argument is the speaker's number")
        }
        return String(localized: "Speaker \(ordinal)", comment: "Unnamed speaker in a transcript; the argument is the speaker's number")
    }

    /// The label used in exports: English and independent of the UI language, like the rest of the JSON keys.
    public var stableLabel: String {
        switch channel {
        case .me: ordinal == 1 ? "Me" : "Me \(ordinal)"
        case .others: "Speaker \(ordinal)"
        }
    }

    /// The name for exports: nil for the user's own entity while it keeps its stored default name.
    var exportName: String? {
        guard source == .user, let entityName else { return nil }
        return entityIsSelf && entityName == MeetingStore.legacySelfName ? nil : entityName
    }
}

/// A speaker as the diarizer finalized it, to be written with `MeetingStore.finalizeSpeakers`.
public struct SpeakerDraft: Sendable, Hashable {
    public var channel: Channel
    public var ordinal: Int
    /// The person a voice profile matched (`.suggested`, as a candidate).
    public var entityID: Int64?
    /// `.auto` or `.suggested`. A user assignment is made with `assignSpeaker`, never here.
    public var source: MeetingSpeaker.Source
    public var confidence: Double?
    /// How tight the speaker's voice cluster is (`SpeakerCentroid.spread`); nil when the diarization measured none.
    public var voiceSpread: Float?

    public init(channel: Channel, ordinal: Int, entityID: Int64? = nil, source: MeetingSpeaker.Source = .auto, confidence: Double? = nil,
                voiceSpread: Float? = nil) {
        self.channel = channel
        self.ordinal = ordinal
        self.entityID = entityID
        self.source = source
        self.confidence = confidence
        self.voiceSpread = voiceSpread
    }
}

/// Which speaker said one segment, as the aligner decided it.
public struct SegmentSpeakerAssignment: Sendable, Hashable {
    /// The segment. With `rightOfSplit`, the segment that request splits (the assignment is for its right part).
    public var segmentID: Int64
    /// Index into the `splits` of the same `finalizeSpeakers` call: the assignment is for the new right
    /// part of that split, whose ID the caller cannot know before the call.
    public var rightOfSplit: Int?
    public var channel: Channel
    public var ordinal: Int
    public var confidence: Double?
    public var overlap: Bool

    public init(segmentID: Int64, channel: Channel, ordinal: Int, confidence: Double? = nil, overlap: Bool = false,
                rightOfSplit: Int? = nil) {
        self.segmentID = segmentID
        self.rightOfSplit = rightOfSplit
        self.channel = channel
        self.ordinal = ordinal
        self.confidence = confidence
        self.overlap = overlap
    }
}

/// A person's voice fingerprint, without the fingerprint (`voice_profiles`).
/// Listing never returns embeddings; matching asks for them explicitly.
public struct VoiceProfile: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let entityID: Int64
    /// The embedding model and version that produced the vector. A profile of another model is unusable.
    public let modelID: String
    public let createdAt: Date
    public let sourceMeetingID: Int64?
    /// When the user attested that the person agreed to have their voice saved.
    public let consentRecordedAt: Date
    /// The last time a suggestion from the profile was accepted (nil: never). Retention proposes the ones
    /// that have not been used in a long time.
    public let lastMatchedAt: Date?
}

/// A profile's vector for matching. Never logged, exported, put in a prompt, indexed or sent anywhere.
public struct VoiceProfileEmbedding: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let profileID: Int64
    public let entityID: Int64
    public let embedding: Data

    public var description: String { "VoiceProfileEmbedding(profile: \(profileID))" }
    public var debugDescription: String { description }
}

/// What a speaker edit changed, enough to put it back with `MeetingStore.undo(_:)`: the speaker rows
/// and segment assignments as they were and, for a split, the text and translations that went.
/// Opaque to callers; it holds no voice data.
public struct SpeakerUndo: Sendable {
    struct SpeakerRow: Sendable {
        var id: Int64, meetingID: Int64, channel: String, ordinal: Int64
        var entityID: Int64?, source: String, confidence: Double?, voiceSpread: Double?
    }
    struct SegmentState: Sendable {
        var id: Int64, meetingID: Int64, speakerID: Int64?, confidence: Double?, overlap: Int64, locked: Int64
    }
    struct Split: Sendable {
        var left: Int64, right: Int64, text: String, end: Double
        /// What the split left behind, so undo can tell that the data moved on (split again, edited, reassigned).
        var leftText: String, rightText: String, at: Double
        var leftSpeaker: Int64?, rightSpeaker: Int64?
        var translations: [(language: String, text: String)]
    }

    /// A task whose owner changed because its speaker was named or unnamed (before and after, a person or nil).
    struct OwnerMove: Sendable {
        var task: Int64
        var before: Int64?, after: Int64?
    }

    var speakers: [SpeakerRow] = []
    var ownerMoves: [OwnerMove] = []
    var segments: [SegmentState] = []
    var split: Split?
    /// The person a rename created: removed again by undo when nothing else uses them.
    var createdPerson: Int64?
    /// The speaker `addSpeaker` created: removed again by undo while no segment points at it.
    var createdSpeaker: Int64?
    /// A suggestion the user rejected for a meeting (meeting, person): undo makes the person suggestible again.
    var rejected: (meeting: Int64, entity: Int64)?
}

/// The result of typing a speaker's name: the person it points to and what undoes it.
public struct SpeakerRename: Sendable {
    public let entityID: Int64
    public let undo: SpeakerUndo
}

/// A split the aligner asks for at finalization: where one segment changes speaker.
public struct SegmentSplitRequest: Sendable, Hashable {
    public var segmentID: Int64
    /// Characters that stay on the left part.
    public var offset: Int
    /// Where the right part starts; interpolated from `offset` when nil.
    public var time: Double?

    public init(segmentID: Int64, offset: Int, time: Double? = nil) {
        self.segmentID = segmentID
        self.offset = offset
        self.time = time
    }
}

/// The result of splitting a segment: the new right part and what undoes the split.
public struct SegmentSplit: Sendable {
    public let rightSegmentID: Int64
    public let undo: SpeakerUndo
}
