// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// "Hi, I'm Ana": the speaker gets "Is this Ana?" when Ana is a person of Context, never a name, and never against the person's choices.
@Suite("Speakers: suggestions from what a speaker said")
struct SpeakerIntroductionSuggestionTests {
    struct Meeting {
        let id: Int64
        let lines: [Int64]
        let speakers: [Int64]
    }

    /// A meeting whose lines are said by Others speakers `1...`, by the index given with each line.
    static func meeting(_ s: MeetingStore, _ lines: [(speaker: Int, text: String)]) async throws -> Meeting {
        let id = try await s.startMeeting(at: .now.addingTimeInterval(-3_600))
        var ids: [Int64] = []
        for (i, line) in lines.enumerated() {
            ids.append(try await s.append(Segment(channel: .others, start: Double(i * 10), end: Double(i * 10 + 8), text: line.text, isFinal: true), to: id))
        }
        try await s.endMeeting(id, at: .now)
        let count = lines.map(\.speaker).max() ?? 1
        try await s.finalizeSpeakers(meetingID: id, speakers: (1...count).map { SpeakerDraft(channel: .others, ordinal: $0) },
                                     assignments: lines.enumerated().map { SegmentSpeakerAssignment(segmentID: ids[$0.offset], channel: .others, ordinal: $0.element.speaker) })
        let speakers = try await s.speakers(of: id).filter { $0.channel == .others }.sorted { $0.ordinal < $1.ordinal }.map(\.id)
        return Meeting(id: id, lines: ids, speakers: speakers)
    }

    static func person(_ s: MeetingStore, _ name: String, aliases: [String] = []) async throws -> Int64 {
        try await s.saveEntity(EntityDraft(kind: .person, name: name, aliases: aliases))
    }

    @Test func aSpeakerWhoSaysWhoTheyAreIsAskedAboutThatPerson() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ana = try await Self.person(s, "Ana García", aliases: ["Ana"])
        _ = try await Self.person(s, "Bruno Díaz")
        let m = try await Self.meeting(s, [(1, "Good morning. Hi, I'm Ana, from Kobaltix."), (2, "Thanks Ana. Let's look at the budget."),
                                           (2, "I'm sure we can ship it."), (3, "I'm Zoe, I take notes today.")])
        #expect(try await s.suggestSpeakersFromIntroductions(meetingID: m.id) == 1)
        let speakers = try await s.speakers(of: m.id)
        let first = try #require(speakers.first { $0.id == m.speakers[0] })
        #expect(first.source == .suggested && first.entityID == ana && first.suggestedBySegment == m.lines[0])
        #expect(first.name == nil, "a suggestion is never shown as a name")
        #expect(speakers.first { $0.id == m.speakers[1] }?.entityID == nil, "being thanked is not saying who you are")
        #expect(speakers.first { $0.id == m.speakers[2] }?.entityID == nil, "Zoe is no person of Context")
        #expect(try await s.suggestSpeakersFromIntroductions(meetingID: m.id) == 0, "once is enough")
    }

    @Test func theAnswerTakesTheLineAwayAndAChoiceIsNeverChanged() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ana = try await Self.person(s, "Ana")
        let m = try await Self.meeting(s, [(1, "Hi, I'm Ana."), (2, "Hello, I'm Bruno.")])
        let bruno = try await Self.person(s, "Bruno")
        // The person named the second speaker already: it stays as they chose.
        _ = try await s.assignSpeaker(m.speakers[1], toEntity: ana)
        try await s.suggestSpeakersFromIntroductions(meetingID: m.id)
        let second = try #require(try await s.speaker(m.speakers[1]))
        #expect(second.source == .user && second.entityID == ana && second.suggestedBySegment == nil)
        #expect(try await s.speaker(m.speakers[0])?.entityID == nil, "Ana belongs to another speaker now")
        // A name the person cleared is their choice too ("nobody"): it is not suggested again.
        _ = try await s.assignSpeaker(m.speakers[1], toEntity: nil)
        try await s.suggestSpeakersFromIntroductions(meetingID: m.id)
        #expect(try await s.speaker(m.speakers[1])?.entityID == nil)

        // Accepting a suggestion makes it the person's own choice: the line no longer explains it.
        let other = try await Self.meeting(s, [(1, "Hello, I'm Bruno.")])
        try await s.suggestSpeakersFromIntroductions(meetingID: other.id)
        let suggested = try #require(try await s.speaker(other.speakers[0]))
        #expect(suggested.suggestedBySegment == other.lines[0] && suggested.entityID == bruno)
        _ = try await s.assignSpeaker(other.speakers[0], toEntity: bruno)
        let accepted = try #require(try await s.speaker(other.speakers[0]))
        #expect(accepted.source == .user && accepted.suggestedBySegment == nil)
    }

    @Test func aRejectedPersonOrTheUserIsNeverSuggested() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ana = try await Self.person(s, "Ana")
        let m = try await Self.meeting(s, [(1, "Hi, I'm Ana.")])
        try await s.suggestSpeakersFromIntroductions(meetingID: m.id)
        #expect(try await s.speaker(m.speakers[0])?.entityID == ana)
        _ = try await s.rejectSuggestion(speakerID: m.speakers[0])
        let rejected = try #require(try await s.speaker(m.speakers[0]))
        #expect(rejected.entityID == nil && rejected.suggestedBySegment == nil)
        #expect(try await s.suggestSpeakersFromIntroductions(meetingID: m.id) == 0, "\"Not Ana\" holds for this meeting")

        let other = try await Self.meeting(s, [(1, "Hello everyone, I'm Lucía.")])
        let me = try await s.selfEntity()
        _ = try await s.saveEntity(EntityDraft(id: me, kind: .person, name: "Lucía"))
        #expect(try await s.suggestSpeakersFromIntroductions(meetingID: other.id) == 0, "the user is never another speaker")
    }

    @Test func twoNamesForOneSpeakerOrOnePersonForTwoSpeakersSuggestNothing() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        _ = try await Self.person(s, "Ana")
        _ = try await Self.person(s, "Bruno")
        let m = try await Self.meeting(s, [(1, "Hi, I'm Ana."), (1, "Hello again, I'm Bruno."), (2, "Hi everyone, I'm Ana.")])
        #expect(try await s.suggestSpeakersFromIntroductions(meetingID: m.id) == 0)
        let shared = try await Self.meeting(s, [(1, "Hi, I'm Ana."), (2, "Hi, I'm Ana.")])
        #expect(try await s.suggestSpeakersFromIntroductions(meetingID: shared.id) == 0)
    }
}
