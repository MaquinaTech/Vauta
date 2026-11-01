// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// "What do you think, Ana?" answered by a speaker, or "Thanks, Ana" after one spoke: that speaker gets "Is this Ana?" when the turns
/// agree, never a name, and never against the person's choices.
@Suite("Speakers: suggestions from names said to a speaker")
struct SpeakerAddressSuggestionTests {
    struct Meeting {
        let id: Int64
        let lines: [Int64]
        let speakers: [Int64]
    }

    /// A meeting whose lines are said by Others speakers `1...` at the times given (8 seconds each), with the confidence given for each
    /// line's speaker (nil: not scored).
    static func meeting(_ s: MeetingStore, _ lines: [(speaker: Int, start: Double, text: String, confidence: Double?)]) async throws -> Meeting {
        let id = try await s.startMeeting(at: .now.addingTimeInterval(-3_600))
        var ids: [Int64] = []
        for line in lines {
            ids.append(try await s.append(Segment(channel: .others, start: line.start, end: line.start + 8, text: line.text, isFinal: true), to: id))
        }
        try await s.endMeeting(id, at: .now)
        let count = lines.map(\.speaker).max() ?? 1
        try await s.finalizeSpeakers(meetingID: id, speakers: (1...count).map { SpeakerDraft(channel: .others, ordinal: $0) },
                                     assignments: lines.enumerated().map {
                                         SegmentSpeakerAssignment(segmentID: ids[$0.offset], channel: .others, ordinal: $0.element.speaker, confidence: $0.element.confidence)
                                     })
        let speakers = try await s.speakers(of: id).filter { $0.channel == .others }.sorted { $0.ordinal < $1.ordinal }.map(\.id)
        return Meeting(id: id, lines: ids, speakers: speakers)
    }

    /// Lines ten seconds apart, every speaker scored as sure.
    static func meeting(_ s: MeetingStore, _ lines: [(speaker: Int, text: String)]) async throws -> Meeting {
        try await meeting(s, lines.enumerated().map { (speaker: $0.element.speaker, start: Double($0.offset * 10), text: $0.element.text, confidence: 0.9) })
    }

    static func person(_ s: MeetingStore, _ name: String, aliases: [String] = [], source: String = "user") async throws -> Int64 {
        try await s.saveEntity(EntityDraft(kind: .person, name: name, aliases: aliases), source: source)
    }

    @Test func theSpeakerWhoAnswersAQuestionByNameIsAskedAboutThatPerson() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ludvik = try await Self.person(s, "Ludvík Novák")
        _ = try await Self.person(s, "Hugo Roux")
        let m = try await Self.meeting(s, [(1, "Uh-huh. What do you have, Ludvík?"), (2, "Okay, I have a PowerPoint presentation."),
                                           (1, "And you have seen it, Ludvík?"), (2, "I saw it, yes."), (3, "Hugo is out today.")])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: m.id) == 1)
        let speakers = try await s.speakers(of: m.id)
        let second = try #require(speakers.first { $0.id == m.speakers[1] })
        #expect(second.source == .suggested && second.entityID == ludvik && second.name == nil, "a suggestion, never a name")
        #expect(second.suggestedBySegment == m.lines[0], "the line that asked them, which another speaker said")
        #expect(speakers.first { $0.id == m.speakers[0] }?.entityID == nil, "who asks is not who is asked")
        #expect(speakers.first { $0.id == m.speakers[2] }?.entityID == nil, "a name talked about says nothing")
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: m.id) == 0, "once is enough")
    }

    @Test func thanksPointToWhoHadJustSpoken() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ana = try await Self.person(s, "Ana García")
        let m = try await Self.meeting(s, [(2, "Here are the figures for March."), (1, "Thanks, Ana. Let's move on to the budget."), (3, "Sure.")])
        try await s.suggestSpeakersFromTranscript(meetingID: m.id)
        #expect(try await s.speaker(m.speakers[1])?.entityID == ana)
        #expect(try await s.speaker(m.speakers[2])?.entityID == nil)
    }

    @Test func turnsThatDisagreeOrAreGuessesOrFarApartSuggestNothing() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        _ = try await Self.person(s, "Hugo Roux")
        // Answered by one speaker, then by another: nobody in particular.
        let split = try await Self.meeting(s, [(1, "What about you, Hugo?"), (3, "I have a piece of paper."),
                                               (2, "Hugo, could you give me the list?"), (1, "Sure, here it is.")])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: split.id) == 0)
        // Twice one speaker and once another: the two win.
        let most = try await Self.meeting(s, [(1, "What about you, Hugo?"), (3, "I have a piece of paper."), (1, "And then, Hugo?"), (3, "Then nothing."),
                                              (2, "Hugo, could you give me the list?"), (1, "Sure, here it is.")])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: most.id) == 1)
        #expect(try await s.speaker(most.speakers[2])?.entityID != nil)
        // The answer's speaker is a guess.
        let guess = try await Self.meeting(s, [(1, 0, "What about you, Hugo?", 0.9), (2, 10, "I have a piece of paper.", 0.3)])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: guess.id) == 0)
        // Nobody answers for half a minute.
        let late = try await Self.meeting(s, [(1, 0, "What about you, Hugo?", 0.9), (2, 40, "I have a piece of paper.", 0.9)])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: late.id) == 0)
    }

    @Test func theAnswerIsTheTurnAfterTheNameNotAReactionToEarlierWords() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let david = try await Self.person(s, "David Ruiz")
        // The name ends a long line: the third speaker's "Yeah" answers its start, the second speaker answers the question (as in AMI IB4004).
        let m = try await Self.meeting(s, [(1, 0, "Okay, so where would we move him, to the room with the windows? Do you have any preferences, David?", 0.9),
                                           (3, 3, "Yeah, that's good.", 0.9), (2, 8.5, "It's completely fine.", 0.9)])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: m.id) == 1)
        #expect(try await s.speaker(m.speakers[1])?.entityID == david)
    }

    @Test func aGivenNameTwoPeopleShareCountsOnlyForTheOneInvited() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        _ = try await Self.person(s, "Ana García")
        let lopez = try await Self.person(s, "Ana López")
        let m = try await Self.meeting(s, [(1, "What do you think, Ana?"), (2, "I agree with the plan.")])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: m.id) == 0, "two people are called Ana")
        try await s.setMeetingEntities(m.id, role: .attendee, [lopez])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: m.id) == 1)
        #expect(try await s.speaker(m.speakers[1])?.entityID == lopez)
    }

    @Test func aPersonInvitedToTheMeetingCountsWithoutBeingInContext() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let carla = try await Self.person(s, "Carla Méndez", source: "calendar")
        let m = try await Self.meeting(s, [(1, "Carla, can you share your screen?"), (2, "Sure, one second.")])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: m.id) == 0, "a calendar person of another meeting is not in Context")
        try await s.setMeetingEntities(m.id, role: .attendee, [carla])
        try await s.suggestSpeakersFromTranscript(meetingID: m.id)
        #expect(try await s.speaker(m.speakers[1])?.entityID == carla)
    }

    @Test func theUserNamedSpeakersAndRejectedPeopleAreNeverTouched() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let me = try await s.selfEntity()
        _ = try await s.saveEntity(EntityDraft(id: me, kind: .person, name: "Lucía Pérez"))
        let bruno = try await Self.person(s, "Bruno Díaz")
        let ana = try await Self.person(s, "Ana García")
        // A question to the user, answered by a remote speaker: that speaker is not the user.
        let mine = try await Self.meeting(s, [(1, "What do you think, Lucía?"), (2, "I think it's fine.")])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: mine.id) == 0)
        // A speaker the person named keeps their choice; a person they said no to is not suggested again for the meeting.
        let m = try await Self.meeting(s, [(1, "Ana, can you hear me?"), (2, "Yes, loud and clear."), (1, "Bruno, and you?"), (3, "Me too.")])
        _ = try await s.assignSpeaker(m.speakers[1], toEntity: bruno)
        try await s.suggestSpeakersFromTranscript(meetingID: m.id)
        let named = try #require(try await s.speaker(m.speakers[1]))
        #expect(named.source == .user && named.entityID == bruno)
        #expect(try await s.speaker(m.speakers[2])?.entityID == nil, "Bruno is the second speaker's, by the person's choice")
        let other = try await Self.meeting(s, [(1, "Ana, can you hear me?"), (2, "Yes, loud and clear.")])
        try await s.suggestSpeakersFromTranscript(meetingID: other.id)
        #expect(try await s.speaker(other.speakers[1])?.entityID == ana)
        _ = try await s.rejectSuggestion(speakerID: other.speakers[1])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: other.id) == 0, "\"Not Ana\" holds for this meeting")
    }

    @Test func whatASpeakerSaysOfThemselvesComesFirst() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ana = try await Self.person(s, "Ana García")
        let bruno = try await Self.person(s, "Bruno Díaz")
        // The third speaker answers "Ana?", but the first said she is Ana: the first is asked about her, the third about nobody. The
        // second answers Bruno.
        let m = try await Self.meeting(s, [(1, "Hi, I'm Ana."), (2, "Welcome. Ana?"), (3, "She dropped out, I think."),
                                           (1, "And Bruno, what do you think?"), (2, "I like it.")])
        #expect(try await s.suggestSpeakersFromTranscript(meetingID: m.id) == 2)
        #expect(try await s.speaker(m.speakers[0])?.entityID == ana)
        #expect(try await s.speaker(m.speakers[1])?.entityID == bruno)
        #expect(try await s.speaker(m.speakers[2])?.entityID == nil)
    }
}
