// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Live notes on the integrated model step aside when a live question waits for the same prefix: that is not an error.
@Suite("Live notes: pre-emption")
struct LiveNotesPreemptionTests {
    @Test func aPreemptedRunIsNilAndTheNextTickReadsTheSameStretch() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is"], locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, options, call in
            if options.purpose == .liveNotes, call == 1 { throw GenerationPreempted() }
            return ScriptedChat.reply(#"{"points": [], "decisions": [], "tasks": []}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: id)
        let first = try await service.liveNotes(meetingID: id, at: 10)
        #expect(first == nil, "no throw: the recorder shows no notice")
        _ = try await service.liveNotes(meetingID: id, at: 20)
        let prompts = chat.calls.filter { $0.options.purpose == .liveNotes }
        #expect(prompts.count == 2 && prompts[0].text == prompts[1].text, "the session did not advance after the pre-emption")
    }
}
