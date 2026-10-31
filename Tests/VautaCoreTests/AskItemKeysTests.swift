// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The minutes' decisions and tasks as keys of Ask's retrieval: a matching item brings in the moment it cites, worded as it was said,
/// and the item's own text never reaches the model.
@Suite("Ask: the minutes' items as keys of the retrieval")
struct AskItemKeysTests {
    static let filler = (1...40).map { "Line \($0) about the agenda, the slides and the coffee machine on the fourth floor." }

    /// A meeting where the decision is said without its words ("yeah, drop it"), and minutes that word it.
    static func meeting(_ f: KnowledgeFixture, at date: Date = .now) async throws -> (meeting: Int64, said: CitableSegment) {
        var lines = filler
        lines[19] = "So what about that extra key on the side, do we keep it?"
        lines[20] = "Yeah, let's drop it, nobody uses it anyway."
        let meeting = try await f.meeting(lines, locale: "en-US", outputLocale: "en-US", at: date)
        let said = try #require(try await f.store.citableSegments(meeting).first { $0.text.hasPrefix("Yeah, let's drop it") })
        var minutes = ValidatedMinutes()
        minutes.decisions = [.init(text: "Remove the teletext button from the remote.", segment: said.id, t: said.start)]
        minutes.tasks = [.init(text: "Update the teletext layout drawings.", owner: nil, due: nil, segment: said.id, t: said.start)]
        try await f.store.applyMinutes(minutes, to: meeting)
        // Off by default until measured to help (`MeetingStore.defaultItemKeyWeight`): the tests turn them on.
        await f.store.setItemKeyWeight(2)
        return (meeting, said)
    }

    @Test func aMatchingDecisionBringsInTheMomentItCites() async throws {
        let f = try KnowledgeFixture()
        let (meeting, said) = try await Self.meeting(f)
        let question = "What did we decide about the teletext button?"
        let found = try await f.store.retrieve(question, queryVector: nil, within: meeting, limit: 3, mode: .keyword)
        #expect(found.contains { $0.segments.contains { $0.id == said.id } }, "the moment the decision cites is sent")
        await f.store.setItemKeyWeight(0)
        let without = try await f.store.retrieve(question, queryVector: nil, within: meeting, limit: 3, mode: .keyword)
        #expect(!without.contains { $0.segments.contains { $0.id == said.id } }, "without the keys, nothing of the transcript says teletext")
    }

    @Test func theyAreOffUntilMeasuredToHelp() async throws {
        let f = try KnowledgeFixture()
        #expect(await f.store.itemKeyWeight == 0 && MeetingStore.defaultItemKeyWeight == 0)
        #expect(try await f.store.itemCitedMoments(terms: ["teletext"], scope: nil).isEmpty)
    }

    @Test func theScopeAndTheShortWindowsUseThemToo() async throws {
        let f = try KnowledgeFixture()
        let (meeting, said) = try await Self.meeting(f)
        let other = try await f.meeting(Self.filler, locale: "en-US", outputLocale: "en-US")
        let question = "What did we decide about the teletext button?"
        #expect(try await f.store.retrieve(question, queryVector: nil, meetings: [other], mode: .keyword).allSatisfy { $0.meeting.id == other },
                "a decision of a meeting out of the scope brings nothing in")
        let windows = try await f.store.retrieve(question, queryVector: nil, within: meeting, mode: .keyword, windows: .standard)
        #expect(windows.contains { $0.segments.contains { $0.id == said.id } })
    }

    @Test func theItemsTextNeverReachesTheModel() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let (_, said) = try await Self.meeting(f)
        _ = try await f.meeting(Self.filler, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in
            guard let (id, text) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
            return ScriptedChat.reply(#"{"found": true, "answer": "x", "claims": [{"text": "x", "citations": [\#(id)], "quote": "\#(text)"}]}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536))
        let result = try await service.ask("What did we decide about the teletext button?", meetingID: nil)
        #expect(result.sent[said.id] != nil, "the moment is sent")
        let request = try #require(chat.calls.last).text
        #expect(!request.contains("Remove the teletext button") && !request.contains("teletext layout drawings"))
    }
}
