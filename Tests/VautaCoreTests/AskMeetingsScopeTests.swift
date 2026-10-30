// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A question limited to some meetings (the time it names, `AskTimeScope`): only their passages are sent, and when none of them
/// matches, the whole library is searched and the result says so.
@Suite("Ask: a question limited to some meetings")
struct AskMeetingsScopeTests {
    @Test func onlyTheMeetingsOfTheScopeAreSentAndNothingThereSearchesThemAll() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let a = try await f.meeting(["The Kobaltix budget was approved for the quarter"], locale: "en-US", outputLocale: "en-US")
        let b = try await f.meeting(["The Kobaltix budget was cut in half by the board"], locale: "en-US", outputLocale: "en-US")
        let c = try await f.meeting(["We talked about the plants in the office"], locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in
            guard let (id, text) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
            return ScriptedChat.reply(#"{"found": true, "answer": "x", "claims": [{"text": "x", "citations": [\#(id)], "quote": "\#(text)"}]}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536))
        let question = "What about the Kobaltix budget?"

        let limited = try await service.ask(question, meetingID: nil, meetings: [b])
        #expect(Set(limited.passages.map(\.meeting.id)) == [b] && !limited.widenedScope)
        let ofB = Set(try await f.store.citableSegments(b).map(\.id))
        #expect(!limited.sent.isEmpty && Set(limited.sent.keys).isSubset(of: ofB), "nothing of the other meetings is sent")

        let nothingThere = try await service.ask(question, meetingID: nil, meetings: [c])
        #expect(nothingThere.widenedScope && Set(nothingThere.passages.map(\.meeting.id)) == [a, b])

        let none = try await service.ask(question, meetingID: nil, meetings: [])
        #expect(none.widenedScope && Set(none.passages.map(\.meeting.id)) == [a, b])

        let all = try await service.ask(question, meetingID: nil)
        #expect(!all.widenedScope && Set(all.passages.map(\.meeting.id)) == [a, b])

        // About one meeting, its whole transcript is read: the set does not apply.
        let one = try await service.ask(question, meetingID: a, meetings: [b])
        #expect(!one.widenedScope && one.sent.values.allSatisfy { $0.text.contains("approved") })
    }
}
