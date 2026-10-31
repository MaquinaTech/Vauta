// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI
import Testing
@testable import Vauta

/// The user's own voice has its own question and its own answers: the localized name “Me” does not fit “Yes, It’s %@”.
@MainActor
@Suite("Speaker suggestion wording")
struct SpeakerSuggestionTests {
    private func texts(_ s: SpeakerSuggestion) -> [String] {
        [s.question, s.yesTitle, s.noTitle, s.yesLabel, s.noLabel].map { String(describing: $0) }
    }

    @Test func theUsersOwnSuggestionNeverPutsTheNameMeInAnAnswer() {
        let own = texts(SpeakerSuggestion(entityID: 1, name: "Me", isSelf: true))
        #expect(own[0].contains("Is this you?"))
        #expect(own[1].contains("Yes, That’s Me") && own[2].contains("No, Not Me"))
        #expect(own[3].contains("Yes, that’s me") && own[4].contains("No, not me"))
        #expect(!own.contains { $0.contains("It’s %@") || $0.contains("Not %@") || $0.contains("not %@") })
    }

    @Test func aSuggestionFromWhatWasSaidQuotesIt() {
        let said = String(describing: SpeakerSuggestion(entityID: 2, name: "Ana", said: "Hi, I'm Ana").explanation)
        #expect(said.contains("Hi, I'm Ana") && !said.contains("voice"), "what the speaker said, not a voice")
        let voice = String(describing: SpeakerSuggestion(entityID: 2, name: "Ana").explanation)
        #expect(voice.contains("voice"))
    }

    @Test func aPersonsSuggestionCarriesTheirName() {
        let ana = texts(SpeakerSuggestion(entityID: 2, name: "Ana"))
        #expect(ana.allSatisfy { $0.contains("Ana") }, "every wording carries the person’s name")
        #expect(!ana.contains { $0.contains("Is this you?") || $0.contains("That’s Me") || $0.contains("Not Me") || $0.contains("not me") })
    }
}
