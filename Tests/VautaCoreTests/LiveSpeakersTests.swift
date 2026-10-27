// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Testing
@testable import VautaCore

@Suite struct LiveSpeakersTests {
    @Test func labelUsesTheNameTheUserGaveTheProvisionalSpeaker() {
        let tag = SpeakerTag(ordinal: 2, confidence: 0.9)
        #expect(LiveSpeakers.label(channel: .others, speaker: tag, names: [2: "Ana"]) == "Ana")
        #expect(LiveSpeakers.label(channel: .others, speaker: tag, names: [3: "Ana"]) == MeetingSpeaker.defaultLabel(channel: .others, ordinal: 2))
    }

    @Test func aCutSentenceNeverFollowsANameCutMidWord() {
        #expect(CaptionSpeakerName.beforeCutSentence("María Fernanda G…") == "María Fernanda")
        #expect(CaptionSpeakerName.beforeCutSentence("Jean-Baptiste Mo…") == "Jean-Baptiste")
        #expect(CaptionSpeakerName.beforeCutSentence("Ana") == "Ana")
        #expect(CaptionSpeakerName.beforeCutSentence("Montgomery-Feathers…") == "Montgomery-Feathers…")
    }

    @Test func namingTargetDoesNotFollowTheLatestVoiceWhileItIsPinned() {
        // Nobody picked a chip: the voice heard last, until the user starts typing and the voice is pinned.
        #expect(LiveSpeakers.namingTarget(speakers: [1, 2, 3], chosen: nil, pinned: nil, latest: 2) == 2)
        #expect(LiveSpeakers.namingTarget(speakers: [1, 2, 3], chosen: nil, pinned: nil, latest: 3) == 3)
        #expect(LiveSpeakers.namingTarget(speakers: [1, 2, 3], chosen: nil, pinned: 2, latest: 3) == 2)
        // A chip the user picked beats the pin; a voice that is gone is ignored.
        #expect(LiveSpeakers.namingTarget(speakers: [1, 2, 3], chosen: 1, pinned: 2, latest: 3) == 1)
        #expect(LiveSpeakers.namingTarget(speakers: [1, 3], chosen: 9, pinned: 8, latest: 3) == 3)
        #expect(LiveSpeakers.namingTarget(speakers: [], chosen: 1, pinned: 2, latest: 3) == nil)
    }

    @Test func labelWithoutSpeakerDataIsTheChannel() {
        #expect(LiveSpeakers.label(channel: .others, speaker: nil, names: [1: "Ana"]) == Channel.others.displayName)
        #expect(LiveSpeakers.label(channel: .me, speaker: SpeakerTag(ordinal: 1), names: [1: "Ana"]) == Channel.me.displayName)
    }

    @Test func carryOverFollowsTheVoiceNotTheNumber() {
        // Live speaker 1 was named Ana; after the final clustering the same voice is speaker 7.
        let live = [LiveSpeakers.LiveSpan(ordinal: 1, start: 0, end: 30), LiveSpeakers.LiveSpan(ordinal: 2, start: 30, end: 60)]
        let stored = [LiveSpeakers.StoredSpan(speakerID: 70, hasPerson: false, start: 0, end: 29),
                      LiveSpeakers.StoredSpan(speakerID: 71, hasPerson: false, start: 31, end: 60)]
        let result = LiveSpeakers.carryOver(named: [1: 500], live: live, stored: stored)
        #expect(result.count == 1)
        #expect(result.first?.speakerID == 70 && result.first?.entityID == 500)
    }

    @Test func carryOverNeverReplacesAnAssignmentOrUsesAPersonTwice() {
        let live = [LiveSpeakers.LiveSpan(ordinal: 1, start: 0, end: 30), LiveSpeakers.LiveSpan(ordinal: 2, start: 0, end: 20)]
        let stored = [LiveSpeakers.StoredSpan(speakerID: 1, hasPerson: true, start: 0, end: 30),
                      LiveSpeakers.StoredSpan(speakerID: 2, hasPerson: false, start: 0, end: 30)]
        // Speaker 1 already has a person: the live names go to speaker 2 only, and the same person is not used twice.
        let result = LiveSpeakers.carryOver(named: [1: 500, 2: 500], live: live, stored: stored)
        #expect(result.count == 1)
        #expect(result.first?.speakerID == 2)
    }

    @Test func carryOverNeverGivesAPersonWhoAlreadyHoldsAnotherSpeaker() {
        let live = [LiveSpeakers.LiveSpan(ordinal: 1, start: 0, end: 30)]
        let stored = [LiveSpeakers.StoredSpan(speakerID: 2, hasPerson: false, start: 0, end: 30)]
        // Person 500 is already speaker 1 of the meeting (named by the user): the voice stays unnamed, not a duplicate.
        #expect(LiveSpeakers.carryOver(named: [1: 500], live: live, stored: stored, alreadyNamed: [500]).isEmpty)
        #expect(LiveSpeakers.carryOver(named: [1: 500], live: live, stored: stored, alreadyNamed: [501]).count == 1)
    }

    @Test func carryOverGivesTheLargerOverlapTheSpeaker() {
        let live = [LiveSpeakers.LiveSpan(ordinal: 1, start: 0, end: 10), LiveSpeakers.LiveSpan(ordinal: 2, start: 10, end: 40)]
        let stored = [LiveSpeakers.StoredSpan(speakerID: 9, hasPerson: false, start: 0, end: 40)]
        let result = LiveSpeakers.carryOver(named: [1: 100, 2: 200], live: live, stored: stored)
        #expect(result.count == 1 && result.first?.entityID == 200)
    }

    @Test func carryOverWithNothingNamedDoesNothing() {
        let result = LiveSpeakers.carryOver(named: [:], live: [.init(ordinal: 1, start: 0, end: 5)],
                                            stored: [.init(speakerID: 1, hasPerson: false, start: 0, end: 5)])
        #expect(result.isEmpty)
    }

    @Test func captionNamesAreShortAndWideScriptsCountDouble() {
        #expect(CaptionSpeakerName.short("Ana") == "Ana")
        let long = CaptionSpeakerName.short("Dr. Alexandria Montgomery-Featherstonehaugh")
        #expect(long.hasSuffix("…") && long.count <= CaptionSpeakerName.limit + 1)
        #expect(CaptionSpeakerName.short("亚历山德里娅·蒙哥马利-费瑟斯通豪博士").count <= CaptionSpeakerName.limit / 2 + 2)
        #expect(CaptionSpeakerName.short("田中 愛子") == "田中 愛子")
    }

    @Test func aNameThatDoesNotFitGivesUpItsTitleBeforeItsSurname() {
        #expect(CaptionSpeakerName.short("Dr. Alexandria Montgomery").hasPrefix("Alexandria"))
        #expect(CaptionSpeakerName.short("Dott.ssa Maria Antonietta Rossi").hasPrefix("Maria"))
        #expect(CaptionSpeakerName.short("Dra. María Fernández-Quiroga").hasPrefix("María"))
        // A name that fits keeps its title; a lone title is never dropped.
        #expect(CaptionSpeakerName.short("Dr. Okafor") == "Dr. Okafor")
        #expect(CaptionSpeakerName.short("Dr.") == "Dr.")
    }
}

@Suite struct CaptionMarkerTests {
    @Test func theMarkerIsOneWordWithoutSentenceEnds() {
        let marker = CaptionSpeakerName.marker(count: 7)
        #expect(!marker.dropLast().contains { $0.isWhitespace || ".!?…".contains($0) })
        #expect(marker.hasSuffix("\u{2002}"))
        #expect(marker.count == 8)
        #expect(CaptionSpeakerName.marker(count: 0).count == 2, "never empty")
    }

    @Test func aWholeCaptionLosesTheMarkerAndAKeptTailNeverShowsAPartOfIt() {
        let marker = CaptionSpeakerName.marker(count: 3)
        let real = "Let’s move the launch."
        #expect(CaptionSpeakerName.unmarked(marker + real, real: real, marker: marker) == (real, true))
        // The layout kept the last words: no name.
        #expect(CaptionSpeakerName.unmarked("…the launch.", real: real, marker: marker) == ("…the launch.", false))
        // A tail that began inside the marker gives only the caption's own text.
        let torn = "na" + "\u{2002}" + real
        #expect(CaptionSpeakerName.unmarked(torn, real: real, marker: marker) == (real, false))
        #expect(CaptionSpeakerName.unmarked("…" + torn, real: real, marker: marker) == ("…" + real, false))
    }
}

@Suite("Speakers: the entity card and the live hand-over")
struct SpeakerCardTests {
    @Test func aPersonSpokeInTheMeetingsWhereTheUserNamedASpeakerWithLines() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        let m1 = try await SpeakerMeeting.make(store)
        try await m1.finalize()
        #expect(try await store.speakerMeetingCount(entityID: ana) == 0, "nobody named yet")
        let one = try await m1.speaker(.others, 1)
        try await store.assignSpeaker(one.id, toEntity: ana)
        #expect(try await store.speakerMeetingCount(entityID: ana) == 1)
        let m2 = try await SpeakerMeeting.make(store, at: .now.addingTimeInterval(-86_400))
        try await m2.finalize()
        try await store.assignSpeaker(try await m2.speaker(.others, 2).id, toEntity: ana)
        #expect(try await store.speakerMeetingCount(entityID: ana) == 2)
        // A speaker the user added and gave no line does not count.
        let m3 = try await SpeakerMeeting.make(store, at: .now.addingTimeInterval(-172_800))
        try await m3.finalize()
        let empty = try await store.addSpeaker(meetingID: m3.meeting, channel: .others)
        try await store.assignSpeaker(empty.speaker.id, toEntity: ana)
        #expect(try await store.speakerMeetingCount(entityID: ana) == 2)
    }

    @Test func theCardListsExactlyTheMeetingsItCounts() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        let spoke = try await SpeakerMeeting.make(store)
        try await spoke.finalize()
        try await store.assignSpeaker(try await spoke.speaker(.others, 1).id, toEntity: ana)
        let other = try await SpeakerMeeting.make(store, at: .now.addingTimeInterval(-86_400))
        try await other.finalize()
        let count = try await store.speakerMeetingCount(entityID: ana)
        let rows = try await store.timeline(ana)
        #expect(count == 1)
        #expect(rows.filter(\.spoke).count == count, "the count and the list come from one definition")
        #expect(rows.map(\.meeting.id) == [spoke.meeting], "a meeting where they only spoke is listed")
    }

    @Test func aMentionCarriesTheSpeakerOfItsLine() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        let one = try await m.speaker(.others, 1)
        try await store.assignSpeaker(one.id, toEntity: ana)
        let segment = try await store.segments(of: m.meeting).first { $0.speaker?.id == one.id }
        #expect(segment?.speaker?.name == "Ana")
    }

    @Test func aCaptionLineKeepsTheSpeakerItWasGivenAsFinal() {
        let line = CaptionLine(id: 1, original: "x", translation: "y", state: .final, speaker: 3)
        #expect(line.speaker == 3)
        #expect(CaptionLine(id: 2, original: "x", translation: "", state: .partial).speaker == nil)
    }
}
