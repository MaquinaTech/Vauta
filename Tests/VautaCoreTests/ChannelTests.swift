// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Channel")
struct ChannelTests {
    @Test(arguments: [
        ("me", Channel.me),
        ("others", Channel.others),
        ("Yo", Channel.me),
        ("Otros", Channel.others),
    ])
    func storedSpeakerMapsCodesAndLegacyLabels(stored: String, expected: Channel) {
        #expect(Channel(storedSpeaker: stored) == expected)
    }

    @Test(arguments: ["", "fichero", "ME", "yo", "otros", "Me", "unknown"])
    func unknownStoredSpeakerFallsBackToOthers(stored: String) {
        #expect(Channel(storedSpeaker: stored) == .others)
    }

    @Test(arguments: Channel.allCases)
    func storedCodeRoundTrips(channel: Channel) {
        #expect(Channel(storedSpeaker: channel.storedCode) == channel)
        #expect(channel.storedCode == channel.rawValue)
    }

    @Test func storedCodesAreStable() {
        #expect(Channel.me.storedCode == "me")
        #expect(Channel.others.storedCode == "others")
        #expect(Channel.allCases == [.me, .others])
    }

    @Test func promptLabelsAreEnglish() {
        // Prompts are English whatever the UI language; the system prompt explains "Me" and "Others".
        #expect(Channel.me.promptLabel == "Me")
        #expect(Channel.others.promptLabel == "Others")
    }

    @Test func displayNamesAreNotEmpty() {
        for channel in Channel.allCases { #expect(!channel.displayName.isEmpty) }
    }

    @Test func codableUsesStoredCode() throws {
        let data = try JSONEncoder().encode([Channel.me, .others])
        #expect(String(decoding: data, as: UTF8.self) == #"["me","others"]"#)
        #expect(try JSONDecoder().decode([Channel].self, from: data) == [.me, .others])
    }

    @Test func promptLineUsesEnglishLabel() {
        let segment = CitableSegment(id: 12345, channel: .others, start: 312, text: "hola")
        #expect(VautaPrompts.line(segment) == "[S12345 · 05:12 · Others] hola")
    }
}
