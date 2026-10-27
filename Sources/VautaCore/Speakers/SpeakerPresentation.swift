// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// How a speaker is shown in lists of transcript lines (the transcript, search results, Ask quotes):
/// the name to print, what to say for VoiceOver and when a label deserves a warning.
extension SpeakerTag {
    /// A line whose speaker was matched with less coverage than this is shown as uncertain.
    /// Confidence is the share of the line the speaker's turn covers (0...1).
    public static let lowConfidenceBelow = 0.6

    /// The label of the speaker: the name the user gave, else "Me", "Me 2" or "Speaker 3".
    public func displayName(channel: Channel) -> String {
        name ?? MeetingSpeaker.defaultLabel(channel: channel, ordinal: ordinal)
    }

    /// The speaker is a guess for this line: scored, and below `lowConfidenceBelow`.
    /// A line the user moved by hand has no score and is never uncertain.
    public var isLowConfidence: Bool {
        guard let confidence else { return false }
        return confidence < Self.lowConfidenceBelow
    }

    /// The label cannot be trusted as fact: a low score, or a line in crosstalk. Exports and Ask citations say so; the
    /// prompt, the chunks and the owner rules treat it the same way.
    public var isDoubtful: Bool { isLowConfidence || overlap }

    /// Where the voice comes from, for VoiceOver: "remote" for the other participants, "in the room" for a
    /// second voice on the user's own microphone, nothing for the user.
    public func role(channel: Channel) -> String? {
        switch channel {
        case .others:
            String(localized: "remote", comment: "VoiceOver: a speaker heard over the call, used after the speaker's name, as in “Ana, remote, 12:04”")
        case .me where ordinal > 1:
            String(localized: "in the room", comment: "VoiceOver: a speaker heard on the user's own microphone who is not the user, used after the name, as in “Ana, in the room, 12:04”")
        case .me:
            nil
        }
    }
}

extension MeetingStore.StoredSegment {
    /// What to print for who said the line: the speaker's label, or the channel when the meeting has no speaker data.
    public var speakerLabel: String {
        speaker?.displayName(channel: channel) ?? channel.displayName
    }

    /// The line's speaker is shown with a warning (low confidence).
    public var hasUncertainSpeaker: Bool { speaker?.isLowConfidence ?? false }
}

/// How Ask cites a passage with its speaker.
public enum CitationLabel {
    /// "Ana", "Speaker 2", "Me" or "Ana (not sure)": who said it. nil only for a meeting without speaker data, so those
    /// citations read as they always did; in a meeting with speakers, the user's own voice is named too, so a row of
    /// citations never has a bare time next to named ones.
    public static func speaker(_ tag: SpeakerTag?, channel: Channel) -> String? {
        guard let tag else { return nil }
        let who = tag.displayName(channel: channel)
        return tag.isDoubtful
            ? String(localized: "\(who) (not sure)", comment: "A speaker’s name followed by a note that the app is not sure who said the line, in an export or an Ask citation")
            : who
    }

    /// "<label> · Ana", or the label unchanged when there is nobody to name.
    public static func label(_ label: String, speaker tag: SpeakerTag?, channel: Channel) -> String {
        guard let shown = speaker(tag, channel: channel) else { return label }
        return String(localized: "citation.with.speaker", defaultValue: "\(label) · \(shown)", comment: "A citation in an Ask answer: the meeting and time, then who said it, as in “Weekly sync · 12:34 · Ana”")
    }
}

/// Numbers for speakers as people read them.
public enum SpeakerFormat {
    /// "45 sec", "12 min", "1 hr, 5 min": rounded to the unit people care about.
    public static func talkTime(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0).rounded())
        if whole < 60 { return Duration.seconds(whole).formatted(.units(allowed: [.seconds], width: .abbreviated)) }
        let minutes = max(1, Int((Double(whole) / 60).rounded()))
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "42%".
    public static func share(_ fraction: Double) -> String {
        min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0)))
    }
}
