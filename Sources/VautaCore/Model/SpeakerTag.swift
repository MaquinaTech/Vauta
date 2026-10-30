// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Who said a segment, when speaker data exists. Every carrier of a segment
/// (`Segment`, `StoredSegment`, `CitableSegment`, `MeetingExport.Line`) holds an
/// optional one: nil means "no speaker data", and then nothing behaves any
/// differently from a store that never had speakers.
///
/// It carries no voice data: never an embedding, never a score other than the
/// assignment's confidence and a flag for a speaker whose voices spread out.
public struct SpeakerTag: Sendable, Hashable {
    /// `meeting_speakers.id`; nil for a provisional live label that is not stored yet.
    public var id: Int64?
    /// The speaker's number within its channel ("Speaker <ordinal>").
    public var ordinal: Int
    /// The name to show: the person the user assigned (typed, or a suggestion accepted).
    /// nil = nobody is named, show "Speaker <ordinal>".
    public var name: String?
    /// How sure the assignment of this segment is (0...1); nil = not scored.
    public var confidence: Double?
    /// The segment lies in a crosstalk span: no name is guessed there.
    public var overlap: Bool
    /// The named person is the user's own entity. The user may name their first microphone voice as somebody else
    /// (a colleague at the laptop): only the user's own entity is "the user".
    public var isSelf: Bool
    /// The speaker's voice cluster is loose (`meeting_speakers.voice_spread` below `VoiceProfileThresholds.minimumSpread`): it
    /// probably holds a second voice, so any of its lines may be somebody else's.
    public var mixesVoices: Bool

    public init(id: Int64? = nil, ordinal: Int, name: String? = nil, confidence: Double? = nil, overlap: Bool = false,
                isSelf: Bool = false, mixesVoices: Bool = false) {
        self.isSelf = isSelf
        self.mixesVoices = mixesVoices
        self.id = id
        self.ordinal = ordinal
        self.name = name
        self.confidence = confidence
        self.overlap = overlap
    }
}
