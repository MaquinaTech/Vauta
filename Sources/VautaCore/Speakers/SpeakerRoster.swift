// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The speakers of the open meeting with what the views need to know about each: how many lines it has, its
/// share of the talking, who else could it be merged with. Pure data derived from the store's rows.
public struct SpeakerRoster: Sendable, Equatable {
    public struct Entry: Sendable, Identifiable, Equatable {
        public let speaker: MeetingSpeaker
        /// Transcript lines assigned to the speaker.
        public let lines: Int
        public var id: Int64 { speaker.id }
        public var displayName: String { speaker.displayName }
        public var channel: Channel { speaker.channel }
    }

    /// The user's channel first, then Others, each by ordinal (the store's order).
    public let entries: [Entry]

    public static let empty = SpeakerRoster(speakers: [], segments: [])

    public init(speakers: [MeetingSpeaker], segments: [MeetingStore.StoredSegment]) {
        var lines: [Int64: Int] = [:]
        for segment in segments { if let id = segment.speaker?.id { lines[id, default: 0] += 1 } }
        entries = speakers.map { Entry(speaker: $0, lines: lines[$0.id] ?? 0) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func entry(_ id: Int64) -> Entry? { entries.first { $0.id == id } }

    /// The speakers a speaker can be merged into or a line moved to: the others of the same channel.
    public func alternatives(to id: Int64) -> [Entry] {
        guard let channel = entry(id)?.channel else { return [] }
        return entries.filter { $0.channel == channel && $0.id != id }
    }

    /// Everything said, in seconds.
    public var totalTalk: Double { entries.reduce(0) { $0 + $1.speaker.talkSeconds } }

    /// The share of the talking of a speaker (0 when nobody talked).
    public func share(of entry: Entry) -> Double {
        totalTalk > 0 ? entry.speaker.talkSeconds / totalTalk : 0
    }

    /// The share as printed: whole percents that add up to exactly 100 (the largest remainders get the leftover points),
    /// so a list of "36%, 29%, 29%, 7%" never reads as an error. 0 when nobody talked.
    public func displayShare(of entry: Entry) -> Double {
        let total = totalTalk
        guard total > 0, entry.speaker.talkSeconds > 0 else { return 0 }
        let exact = entries.map { $0.speaker.talkSeconds / total * 100 }
        var whole = exact.map { Int($0.rounded(.down)) }
        let leftover = 100 - whole.reduce(0, +)
        let order = exact.indices.sorted { (exact[$0] - Double(whole[$0]), -Double($0)) > (exact[$1] - Double(whole[$1]), -Double($1)) }
        for index in order.prefix(max(leftover, 0)) { whole[index] += 1 }
        guard let position = entries.firstIndex(where: { $0.id == entry.id }) else { return 0 }
        return Double(whole[position]) / 100
    }

    /// Who spoke, most first; ties by transcript order. Speakers with no line and no time are left out
    /// (an empty speaker is one the user just added and has not used yet).
    public var byTalkTime: [Entry] {
        entries.enumerated()
            .filter { $0.element.lines > 0 || $0.element.speaker.talkSeconds > 0 }
            .sorted { ($0.element.speaker.talkSeconds, $1.offset) > ($1.element.speaker.talkSeconds, $0.offset) }
            .map(\.element)
    }

    /// Every name the transcript can print, to size the speaker column over all of them.
    public var labels: [String] { entries.map(\.displayName) }

    /// The line and the lines after it that the same speaker said without anyone else in between:
    /// "the rest of the turn", what "Split from here" moves. Empty when the line has no speaker.
    public static func restOfTurn(from segmentID: Int64, in segments: [MeetingStore.StoredSegment]) -> [MeetingStore.StoredSegment] {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }), let speaker = segments[index].speaker?.id else { return [] }
        return Array(segments[index...].prefix { $0.speaker?.id == speaker })
    }
}

/// Who the user can pick for a speaker. Calendar attendees are suggestions shown first, never assigned by
/// themselves, even when there are as many attendees as speakers.
public enum SpeakerCandidates {
    /// `attendees`: the people the meeting's calendar event lists; `people`: everyone in the user's context.
    /// The user's own entry is offered for the user's channel only. Nobody appears twice.
    public static func split(attendees: [Entity], people: [Entity], for speaker: MeetingSpeaker) -> (suggested: [Entity], people: [Entity]) {
        func eligible(_ entity: Entity) -> Bool { entity.kind == .person && (speaker.channel == .me || !entity.isSelf) }
        let suggested = attendees.filter(eligible)
        let taken = Set(suggested.map(\.id))
        let rest = people.filter { eligible($0) && !taken.contains($0.id) }
        // Yourself first, as everywhere in the app.
        return (suggested, rest.filter(\.isSelf) + rest.filter { !$0.isSelf })
    }
}
