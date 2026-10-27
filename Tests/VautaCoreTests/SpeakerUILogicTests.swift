// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Speaker UI: roster, labels and colours")
struct SpeakerRosterTests {
    private func line(_ id: Int64, _ channel: Channel, speaker: SpeakerTag?) -> MeetingStore.StoredSegment {
        MeetingStore.StoredSegment(id: id, meetingID: 1, channel: channel, start: Double(id), end: Double(id) + 1, text: "x", speaker: speaker)
    }

    @Test func theRosterCountsLinesAndSharesTheTalking() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let roster = SpeakerRoster(speakers: try await store.speakers(of: m.meeting), segments: try await store.segments(of: m.meeting))
        #expect(roster.entries.map(\.lines) == [1, 2, 1], "Me, Speaker 1 (two lines), Speaker 2")
        #expect(abs(roster.entries.map { roster.share(of: $0) }.reduce(0, +) - 1) < 1e-9)
        #expect(roster.byTalkTime.first?.displayName == MeetingSpeaker.defaultLabel(channel: .others, ordinal: 1), "most talking first")
        #expect(roster.labels.count == 3)
    }

    @Test func printedSharesAddUpToOneHundredPercent() {
        // 214 s, 172 s, 172 s and 42 s: 35.7, 28.6, 28.6 and 7.1 %, which round to 36, 29, 29 and 7 (101).
        let times: [Double] = [214, 172, 172, 42]
        let speakers = times.enumerated().map { MeetingSpeaker(id: Int64($0.offset + 1), meetingID: 1, channel: .others, ordinal: $0.offset + 1, talkSeconds: $0.element) }
        let roster = SpeakerRoster(speakers: speakers, segments: [])
        let printed = roster.entries.map { Int((roster.displayShare(of: $0) * 100).rounded()) }
        #expect(printed.reduce(0, +) == 100)
        #expect(printed.first == 36 && printed.last == 7)
        #expect(SpeakerRoster.empty.entries.isEmpty)
    }

    @Test func aSpeakerNobodyUsedYetIsNotListedAsHavingSpoken() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        _ = try await store.addSpeaker(meetingID: m.meeting, channel: .others)
        let roster = SpeakerRoster(speakers: try await store.speakers(of: m.meeting), segments: try await store.segments(of: m.meeting))
        #expect(roster.entries.count == 4)
        #expect(roster.byTalkTime.count == 3)
    }

    @Test func alternativesAreTheOtherSpeakersOfTheSameChannel() async throws {
        let fx = StoreFixture()
        defer { withExtendedLifetime(fx) {} }
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let roster = SpeakerRoster(speakers: try await store.speakers(of: m.meeting), segments: try await store.segments(of: m.meeting))
        let one = try await m.speaker(.others, 1), me = try await m.speaker(.me, 1)
        #expect(roster.alternatives(to: one.id).map(\.speaker.ordinal) == [2])
        #expect(roster.alternatives(to: me.id).isEmpty, "the user's channel has one speaker")
    }

    @Test func theRestOfATurnStopsWhereAnotherSpeakerStarts() {
        let a = SpeakerTag(id: 1, ordinal: 1), b = SpeakerTag(id: 2, ordinal: 2)
        let lines = [line(1, .others, speaker: a), line(2, .others, speaker: a), line(3, .others, speaker: b), line(4, .others, speaker: a)]
        #expect(SpeakerRoster.restOfTurn(from: 2, in: lines).map(\.id) == [2])
        #expect(SpeakerRoster.restOfTurn(from: 1, in: lines).map(\.id) == [1, 2])
        #expect(SpeakerRoster.restOfTurn(from: 4, in: lines).map(\.id) == [4])
        #expect(SpeakerRoster.restOfTurn(from: 99, in: lines).isEmpty)
        #expect(SpeakerRoster.restOfTurn(from: 1, in: [line(1, .others, speaker: nil)]).isEmpty, "a line with no speaker has no turn")
    }

    @Test func linesPrintTheSpeakerOrTheChannel() {
        let named = line(1, .others, speaker: SpeakerTag(id: 1, ordinal: 2, name: "Ana"))
        let unnamed = line(2, .others, speaker: SpeakerTag(id: 2, ordinal: 3))
        let plain = line(3, .me, speaker: nil)
        #expect(named.speakerLabel == "Ana")
        #expect(unnamed.speakerLabel == MeetingSpeaker.defaultLabel(channel: .others, ordinal: 3))
        #expect(plain.speakerLabel == Channel.me.displayName, "no speaker data: as before")
        #expect(line(4, .me, speaker: SpeakerTag(id: 4, ordinal: 2)).speakerLabel == MeetingSpeaker.defaultLabel(channel: .me, ordinal: 2))
    }

    @Test func aLowConfidenceLineIsMarkedButAHandMadeOneIsNot() {
        #expect(SpeakerTag(ordinal: 1, confidence: 0.4).isLowConfidence)
        #expect(!SpeakerTag(ordinal: 1, confidence: 0.6).isLowConfidence)
        #expect(!SpeakerTag(ordinal: 1, confidence: nil).isLowConfidence, "the user's own word has no score")
        #expect(line(1, .others, speaker: SpeakerTag(ordinal: 1, confidence: 0.2)).hasUncertainSpeaker)
        #expect(!line(2, .others, speaker: nil).hasUncertainSpeaker)
    }

    @Test func voiceOverSaysWhereTheVoiceComesFrom() {
        #expect(SpeakerTag(ordinal: 1).role(channel: .others) != nil)
        #expect(SpeakerTag(ordinal: 1).role(channel: .me) == nil)
        #expect(SpeakerTag(ordinal: 2).role(channel: .me) != nil, "a second voice on the microphone")
    }

    @Test func talkTimeAndShareAreFormattedForPeople() {
        #expect(SpeakerFormat.talkTime(0) == Duration.seconds(0).formatted(.units(allowed: [.seconds], width: .abbreviated)))
        #expect(SpeakerFormat.talkTime(59.4).contains("59"))
        #expect(SpeakerFormat.talkTime(12 * 60 + 10).contains("12"))
        #expect(SpeakerFormat.share(0.425).contains("4"))
        #expect(SpeakerFormat.share(7) == SpeakerFormat.share(1), "clamped")
    }

    // MARK: Colours

    @Test func everySpeakerColourReadsOnItsBackground() {
        let light = SpeakerPalette.RGB(red: 1, green: 1, blue: 1)
        // The light grey of the captions panel and the cards (241 of 255): the small speaker names sit on it as well.
        let grey = SpeakerPalette.RGB(red: 0.945, green: 0.945, blue: 0.945)
        // The darkest backgrounds a transcript sits on (windowBackground in dark appearance is about 0.12 grey).
        let dark = SpeakerPalette.RGB(red: 0.11, green: 0.11, blue: 0.12)
        for channel in Channel.allCases {
            for ordinal in 1...14 {
                let l = SpeakerPalette.color(channel: channel, ordinal: ordinal, dark: false)
                let d = SpeakerPalette.color(channel: channel, ordinal: ordinal, dark: true)
                #expect(l.contrast(with: light) >= 4.5, "\(channel) \(ordinal) on light: \(l.contrast(with: light))")
                #expect(l.contrast(with: grey) >= 4.5, "\(channel) \(ordinal) on light grey: \(l.contrast(with: grey))")
                #expect(d.contrast(with: dark) >= 4.5, "\(channel) \(ordinal) on dark: \(d.contrast(with: dark))")
            }
        }
    }

    @Test func neighbouringSpeakersGetDifferentColours() {
        func distance(_ a: SpeakerPalette.RGB, _ b: SpeakerPalette.RGB) -> Double {
            ((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green) + (a.blue - b.blue) * (a.blue - b.blue)).squareRoot()
        }
        for channel in Channel.allCases {
            for dark in [false, true] {
                let colours = (1...8).map { SpeakerPalette.color(channel: channel, ordinal: $0, dark: dark) }
                for index in 0..<colours.count - 1 {
                    // Two rose shades one step apart once read as one colour in the captions: neighbours stay clearly apart.
                    #expect(distance(colours[index], colours[index + 1]) >= 0.2, "\(channel) \(index + 1) and \(index + 2), dark: \(dark)")
                }
                // No two of the first eight speakers share a colour.
                // The first speaker of a channel is drawn in the channel's own system colour, not the table's first hue (that
                // one is only a stand-in here, and system purple is lighter than the deep violet of speaker 6): leave it out.
                for i in 1..<colours.count {
                    for j in (i + 1)..<colours.count { #expect(distance(colours[i], colours[j]) >= 0.15, "\(channel) \(i + 1) and \(j + 1), dark: \(dark)") }
                }
            }
        }
        for channel in Channel.allCases {
            for ordinal in 1..<12 {
                #expect(SpeakerPalette.color(channel: channel, ordinal: ordinal, dark: false) != SpeakerPalette.color(channel: channel, ordinal: ordinal + 1, dark: false))
            }
        }
    }

    @Test func theOthersHuesStayAwayFromTheUsersTealAndFromLinkBlue() {
        for ordinal in 2...8 {
            let others = SpeakerPalette.swatches(.others)[ordinal - 1]
            #expect(others.chroma < 0.5 || abs(others.hue - 0.49) > 0.15, "ordinal \(ordinal) is not teal")
            #expect(others.chroma < 0.5 || abs(others.hue - 0.6) > 0.12, "ordinal \(ordinal) is not link blue")
        }
    }

    @Test func noSpeakerColourIsAGreyOrNearlyTheBodyText() {
        for channel in [Channel.others] {
            for ordinal in 1...8 {
                for dark in [false, true] {
                    let c = SpeakerPalette.color(channel: channel, ordinal: ordinal, dark: dark)
                    let spread = max(c.red, c.green, c.blue) - min(c.red, c.green, c.blue)
                    // A grey or a near-white reads as plain or disabled text, not as a speaker.
                    #expect(spread >= 0.2, "\(channel) \(ordinal), dark: \(dark), spread \(spread)")
                }
            }
        }
    }

    // MARK: Candidates

    @Test func calendarAttendeesComeFirstAndOthersFollowWithoutDuplicates() {
        func person(_ id: Int64, _ name: String, isSelf: Bool = false, kind: EntityKind = .person) -> Entity {
            Entity(id: id, kind: kind, name: name, note: nil, email: nil, source: "user", confirmed: true, aliases: [], lastSeen: nil,
                   mentionCount: 0, isSelf: isSelf)
        }
        let me = person(1, "Me", isSelf: true), ana = person(2, "Ana"), bea = person(3, "Bea"), project = person(4, "Atlas", kind: .project)
        let remote = MeetingSpeaker(id: 1, meetingID: 1, channel: .others, ordinal: 1)
        let local = MeetingSpeaker(id: 2, meetingID: 1, channel: .me, ordinal: 1)
        let forRemote = SpeakerCandidates.split(attendees: [bea], people: [me, ana, bea, project], for: remote)
        #expect(forRemote.suggested.map(\.id) == [3])
        #expect(forRemote.people.map(\.id) == [2], "no self for a remote voice, no projects, no duplicates")
        let forMe = SpeakerCandidates.split(attendees: [], people: [ana, me], for: local)
        #expect(forMe.people.map(\.id) == [1, 2], "yourself first")
    }
}

@Suite("Speaker UI: edits, undo and persistence")
struct SpeakerEditorTests {
    /// The fixture's folder is deleted with it: the tests hold the rig for as long as they run.
    struct Rig {
        let fx: StoreFixture
        let m: SpeakerMeeting
        let editor: SpeakerEditor
        let store: MeetingStore
    }

    private func rig() async throws -> Rig {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        return Rig(fx: fx, m: m, editor: SpeakerEditor(store: store), store: store)
    }

    private func tags(_ store: MeetingStore, _ meeting: Int64) async throws -> [Int?] {
        try await store.segments(of: meeting).map { $0.speaker.map { $0.ordinal } }
    }

    @Test func namingASpeakerPersistsAndUndoRestoresIt() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        let one = try await m.speaker(.others, 1)
        let outcome = try await editor.apply(.name(speaker: one.id, name: "Ana Ruiz"))
        #expect(outcome.kind == .name)
        #expect(try await store.segments(of: m.meeting).compactMap(\.speaker?.name).contains("Ana Ruiz"))
        #expect(try await m.speaker(.others, 1).source == .user)
        try await editor.undo(outcome)
        #expect(try await store.segments(of: m.meeting).compactMap(\.speaker?.name).isEmpty)
        #expect(try await store.entities().allSatisfy { $0.name != "Ana Ruiz" }, "the person the naming created goes with it")
    }

    @Test func aTypedNameThatSeveralPeopleShareAsksWhichOne() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        _ = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana Ruiz", aliases: ["Ana"]))
        _ = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana Soto", aliases: ["Ana"]))
        await expectStoreError(.speakerNameAmbiguous) { _ = try await editor.apply(.name(speaker: try await m.speaker(.others, 1).id, name: "Ana")) }
        #expect(try await m.speaker(.others, 1).entityID == nil, "nothing was assigned")
    }

    @Test func assigningAPersonAndClearingTheNameAreUndoable() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        let one = try await m.speaker(.others, 1)
        let assign = try await editor.apply(.assign(speaker: one.id, entity: ana))
        #expect(try await m.speaker(.others, 1).entityID == ana)
        let clear = try await editor.apply(.assign(speaker: one.id, entity: nil))
        #expect(clear.kind == .clearName)
        #expect(try await m.speaker(.others, 1).entityID == nil)
        try await editor.undo(clear)
        #expect(try await m.speaker(.others, 1).entityID == ana)
        try await editor.undo(assign)
        #expect(try await m.speaker(.others, 1).entityID == nil)
    }

    @Test func aUserAssignmentSurvivesFinalizingAgain() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        try await editor.apply(.assign(speaker: try await m.speaker(.others, 1).id, entity: ana))
        try await editor.apply(.name(speaker: try await m.speaker(.others, 2).id, name: "Bea"))
        try await m.finalize()
        let names = try await store.segments(of: m.meeting).map { $0.speaker?.name }
        #expect(names == [nil, "Ana", "Bea", "Ana"], "what the views read after the diarizer ran again")
        let roster = SpeakerRoster(speakers: try await store.speakers(of: m.meeting), segments: try await store.segments(of: m.meeting))
        #expect(roster.entries.compactMap(\.speaker.name) == ["Ana", "Bea"])
    }

    @Test func aMergeIsUndoableAndSurvivesFinalizingAgain() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        let (one, two) = (try await m.speaker(.others, 1).id, try await m.speaker(.others, 2).id)
        let outcome = try await editor.apply(.merge(source: two, into: one))
        #expect(try await tags(store, m.meeting) == [1, 1, 1, 1])
        try await m.finalize()
        #expect(try await tags(store, m.meeting) == [1, 1, 1, 1], "the user's merge wins over the diarizer")
        _ = outcome
    }

    @Test func undoingAMergeBringsTheSpeakerBack() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        let (one, two) = (try await m.speaker(.others, 1).id, try await m.speaker(.others, 2).id)
        let outcome = try await editor.apply(.merge(source: two, into: one))
        try await editor.undo(outcome)
        #expect(try await tags(store, m.meeting) == [1, 1, 2, 1])
        #expect(try await store.speakers(of: m.meeting).count == 3)
    }

    @Test func movingALineToAnotherSpeakerAndToANewOne() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        let two = try await m.speaker(.others, 2).id
        let move = try await editor.apply(.moveLine(segment: m.segments[1], to: two))
        #expect(try await tags(store, m.meeting) == [1, 2, 2, 1])
        try await editor.undo(move)
        #expect(try await tags(store, m.meeting) == [1, 1, 2, 1])

        let fresh = try await editor.apply(.moveLineToNewSpeaker(segment: m.segments[3], meeting: m.meeting))
        #expect(try await tags(store, m.meeting) == [1, 1, 2, 3])
        #expect(try await store.speakers(of: m.meeting).count == 4)
        try await editor.undo(fresh)
        #expect(try await tags(store, m.meeting) == [1, 1, 2, 1])
        #expect(try await store.speakers(of: m.meeting).count == 3, "the speaker the edit added goes away")
    }

    @Test func aMovedLineStaysWhereTheUserPutItWhenFinalizingAgain() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        try await editor.apply(.moveLine(segment: m.segments[1], to: try await m.speaker(.others, 2).id))
        try await m.finalize()
        #expect(try await tags(store, m.meeting) == [1, 2, 2, 1])
    }

    @Test func splitFromHereMovesTheRestOfTheTurnToANewSpeaker() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        // One turn of three lines for Speaker 1 (the diarizer merged a second voice into it).
        try await store.reassignSegment(m.segments[2], toSpeaker: try await m.speaker(.others, 1).id)
        #expect(try await tags(store, m.meeting) == [1, 1, 1, 1])
        let outcome = try await editor.apply(.splitFromHere(segment: m.segments[2], meeting: m.meeting))
        #expect(outcome.kind == .split)
        #expect(try await tags(store, m.meeting) == [1, 1, 3, 3], "the new speaker takes the next free number")
        try await editor.undo(outcome)
        #expect(try await tags(store, m.meeting) == [1, 1, 1, 1])
        #expect(try await store.speakers(of: m.meeting).filter { $0.channel == .others }.map(\.ordinal) == [1, 2], "the new speaker is gone again")
    }

    @Test func splitFromHereOnALineWithoutASpeakerFails() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        _ = try await store.clearSpeakers(meetingID: m.meeting)
        await expectStoreError(.segmentGone) { _ = try await editor.apply(.splitFromHere(segment: m.segments[1], meeting: m.meeting)) }
        #expect(try await store.speakers(of: m.meeting).isEmpty, "nothing was added")
    }

    @Test func turningSeparationOffRemovesSpeakersAndUndoBringsThemBack() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        try await editor.apply(.name(speaker: try await m.speaker(.others, 1).id, name: "Ana"))
        let off = try await editor.apply(.turnOffSeparation(meeting: m.meeting))
        #expect(try await store.speakersOff(meetingID: m.meeting))
        #expect(try await store.speakers(of: m.meeting).isEmpty)
        #expect(try await store.segments(of: m.meeting).allSatisfy { $0.speaker == nil }, "renders like a meeting from before speakers")
        try await m.finalize()
        #expect(try await store.speakers(of: m.meeting).isEmpty, "a new diarization writes nothing while the switch is on")
        try await editor.undo(off)
        #expect(try await store.speakersOff(meetingID: m.meeting) == false)
        #expect(try await store.speakers(of: m.meeting).count == 3)
        #expect(try await store.segments(of: m.meeting).compactMap(\.speaker?.name).contains("Ana"), "the name the user gave is back")
    }

    @Test func turningSeparationBackOnIsUndoable() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        try await editor.apply(.turnOffSeparation(meeting: m.meeting))
        let on = try await editor.apply(.turnOnSeparation(meeting: m.meeting))
        #expect(try await store.speakersOff(meetingID: m.meeting) == false)
        try await editor.undo(on)
        #expect(try await store.speakersOff(meetingID: m.meeting))
    }

    @Test func everyEditHasAnActionNameForTheEditMenu() {
        for kind in [SpeakerEditKind.name, .clearName, .merge, .moveLine, .split, .turnOff, .turnOn] {
            #expect(!kind.actionName.isEmpty)
        }
    }

    @Test func undoFailsCleanlyWhenTheDataMovedOn() async throws {
        let r = try await rig()
        let (m, editor, store) = (r.m, r.editor, r.store)
        defer { withExtendedLifetime(r) {} }
        let (one, two) = (try await m.speaker(.others, 1).id, try await m.speaker(.others, 2).id)
        let merge = try await editor.apply(.merge(source: two, into: one))
        _ = try await store.clearSpeakers(meetingID: m.meeting)
        try await store.setSpeakersOff(true, meetingID: m.meeting)
        await #expect(throws: (any Error).self) { try await editor.undo(merge) }
    }
}
