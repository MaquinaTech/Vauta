// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// How an Ask citation names the speaker, and who is "the user" in a prompt line.
@Suite("Ask citations with speakers")
struct CitationLabelTests {
    private func label(_ tag: SpeakerTag?, _ channel: Channel = .others) -> String {
        CitationLabel.label("Weekly sync · 12:34", speaker: tag, channel: channel)
    }

    @Test func aNamedSpeakerIsShownByName() {
        #expect(label(SpeakerTag(id: 1, ordinal: 2, name: "Ana", confidence: 0.9)) == "Weekly sync · 12:34 · Ana")
    }

    @Test func anUnnamedSpeakerIsShownAsSpeakerK() {
        #expect(label(SpeakerTag(id: 1, ordinal: 2, confidence: 0.9)) == "Weekly sync · 12:34 · Speaker 2")
    }

    @Test func aDoubtfulLabelSaysSoWhetherItIsLowConfidenceOrCrosstalk() {
        let notSure = String(localized: "Speaker 2 (not sure)")
        #expect(label(SpeakerTag(id: 1, ordinal: 2, confidence: 0.3)) == "Weekly sync · 12:34 · " + notSure)
        #expect(label(SpeakerTag(id: 1, ordinal: 2, confidence: 0.95, overlap: true)) == "Weekly sync · 12:34 · " + notSure)
        #expect(label(SpeakerTag(id: 1, ordinal: 2, name: "Ana", confidence: 0.2)).hasSuffix(String(localized: "Ana (not sure)")))
        // A line the user placed by hand has no score and is never doubtful.
        #expect(label(SpeakerTag(id: 1, ordinal: 2, name: "Ana")) == "Weekly sync · 12:34 · Ana")
    }

    @Test func meetingsWithoutSpeakersReadAsBeforeAndTheUsersVoiceIsNamedInTheOthers() {
        #expect(label(nil, .others) == "Weekly sync · 12:34")
        #expect(label(nil, .me) == "Weekly sync · 12:34")
        // With speaker data the user's own voice is named too, as "Me".
        #expect(label(SpeakerTag(id: 1, ordinal: 1, confidence: 0.99), .me) == "Weekly sync · 12:34 · " + Channel.me.displayName)
        // A named first voice on the user's microphone, and a second voice in the room, are shown.
        #expect(label(SpeakerTag(id: 1, ordinal: 1, name: "Carlos"), .me) == "Weekly sync · 12:34 · Carlos")
        #expect(label(SpeakerTag(id: 2, ordinal: 2, confidence: 0.9), .me) == "Weekly sync · 12:34 · Me 2")
    }

    @Test func longLabelsStayInOneLine() {
        let long = label(SpeakerTag(id: 1, ordinal: 2, name: "Maria-Magdalena von Hohenzollern-Sigmaringen", confidence: 0.2))
        #expect(!long.contains("\n"))
    }

    @Test func onlyTheUsersOwnEntityIsTheUserInAPrompt() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let carlos = try await store.saveEntity(EntityDraft(kind: .person, name: "Carlos"))
        let speaker = try await m.speaker(.me, 1).id
        _ = try await store.assignSpeaker(speaker, toEntity: carlos)
        func promptLine() async throws -> String {
            let segment = try #require(try await store.citableSegments(m.meeting).first { $0.channel == .me })
            return VautaPrompts.line(segment)
        }
        #expect(try await promptLine().contains("Carlos (in the room)]"))
        let own = try await store.selfEntity()
        _ = try await store.saveEntity(EntityDraft(id: own, kind: .person, name: "Maya"))
        _ = try await store.assignSpeaker(speaker, toEntity: own)
        #expect(try await promptLine().contains("Maya (the user)]"))
    }
}
