// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Minutes of a meeting of 30 to 60 minutes on Apple's 4,096-token window. The final request used to ask for the whole minutes
/// again from the extracts and was cut off at the length limit; now it reads a digest and writes only the language parts.
@Suite("Minutes: long meetings on a small window")
struct MinutesSmallWindowTests {
    static let sentence = "We went through the quarterly budget of the Kobaltix project line by line and agreed on the next steps for"

    /// A block extract like the one the model writes: a summary, one decision and one task that cite the block's first segment.
    static func extract(_ messages: [ChatMessage]) -> String {
        guard let (id, text) = ScriptedChat.firstSegment(messages) else { return "{}" }
        let quote = String(text.prefix(40))
        return """
            {"summary": "The block covers the budget of segment \(id).", "topics": ["budget \(id)"],
             "decisions": [{"text": "Keep the budget \(id)", "seg": \(id), "quote": "\(quote)"}],
             "tasks": [{"text": "Send the numbers \(id)", "owner": null, "owner_id": null, "due": null, "seg": \(id), "quote": "\(quote)"}],
             "entities": [], "open_questions": ["Who signs \(id)?"]}
            """
    }

    static let finalReply = #"{"title": "Quarterly budget", "summary": "The team went through the whole budget.", "topics": ["budget", "next steps"], "open_questions": ["Who signs?"]}"#

    private func run(_ f: KnowledgeFixture, _ id: Int64, chat: ScriptedChat, legacy: Bool = false) async throws -> LLMService.JobEvent.Outcome? {
        let events = EventLog()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        if legacy { await service.setMinutesExtraction(.legacy); await service.setMinutesQuestions(.legacy) }
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        let outcome = events.events.last?.outcome
        await service.waitUntilQueueIdle()
        return outcome
    }

    @Test func theFinalRequestReadsADigestAndWritesOnlyTheLanguageParts() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<260).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, options, _ in
            // Every request fits the window with its answer.
            #expect(PromptText.tokens(messages) + options.maxTokens <= 4_096, "\(PromptText.tokens(messages)) + \(options.maxTokens)")
            let last = messages.last?.content ?? ""
            if last.contains("ONLY one block") { return ScriptedChat.reply(Self.extract(messages)) }
            return ScriptedChat.reply(Self.finalReply)
        }
        // The digest and the items as the old extraction writes them (Apple's release choice ranks the list and checks the questions).
        let outcome = try await run(f, id, chat: chat, legacy: true)
        #expect(outcome == .succeeded)
        let blocks = chat.calls.filter { $0.text.contains("<<<BLOCK") }
        #expect(blocks.count >= 4)
        let final = try #require(chat.calls.last { !$0.text.contains("actually decided in the transcript") && !$0.text.contains("This is the end of the meeting") })
        #expect(final.text.contains("<<<NOTES ON THE BLOCKS OF THE MEETING") && !final.text.contains("<<<EXTRACTS"))
        #expect(final.messages.last?.content.contains("Above are notes on consecutive blocks") == true)
        #expect(!final.text.contains("\"quote\"") && !final.text.contains("\"decisions\": [{"), "the final request neither carries nor asks for the items")
        #expect(final.options.maxTokens <= 900, "a few hundred tokens of answer, not the 1,228 that were cut off")
        #expect(chat.calls.filter { $0.text.contains("ONE compact extract") }.isEmpty, "no merge rounds: the digest is read instead")
        // The decisions and tasks come from the extracts, each checked against its segment.
        let decisions = try await f.store.decisions(id)
        #expect(decisions.count == blocks.count && decisions.allSatisfy { $0.text.hasPrefix("Keep the budget") })
        #expect(try await f.store.tasks(id).count == blocks.count)
        let card = try await f.store.card(id)
        #expect(card?.summary == "The team went through the whole budget." && card?.openQuestions == ["Who signs?"])
    }

    @Test func aFinalAnswerThatIsStillCutOffFailsTheJobInsteadOfStoringHalfMinutes() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<120).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, _ in
            messages.last?.content.contains("ONLY one block") == true ? ScriptedChat.reply(Self.extract(messages)) : ScriptedChat.reply(#"{"title": "Quart"#, finish: .length)
        }
        let outcome = try await run(f, id, chat: chat)
        guard case .failed? = outcome else { Issue.record("expected a failure, got \(String(describing: outcome))"); return }
    }

    @Test func aFinalAnswerCutOffAfterItsFirstFieldsKeepsWhatWasFinished() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<120).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, _ in
            messages.last?.content.contains("ONLY one block") == true ? ScriptedChat.reply(Self.extract(messages))
                : ScriptedChat.reply(#"{"title": "Quarterly budget", "summary": "The team went through the whole budget.", "topics": ["budget", "next st"#, finish: .length)
        }
        let outcome = try await run(f, id, chat: chat)
        #expect(outcome == .succeeded)
        let card = try await f.store.card(id)
        #expect(card?.summary == "The team went through the whole budget." && card?.topics == ["budget"], "the finished fields stay, the half-written topic goes: \(String(describing: card))")
        #expect(try await f.store.decisions(id).isEmpty == false, "the items from the extracts are there")
    }

    @Test func aTruncatedJSONObjectIsClosedAtItsLastCompleteElementAndNeverCompleted() {
        func closed(_ text: String) -> String? { ModelOutput.closingTruncatedJSON(text) }
        #expect(closed(#"{"a": "x", "b": ["p", "q", "r"#) == #"{"a": "x", "b": ["p", "q"]}"#)
        #expect(closed(#"{"a": "x", "b": ["p"], "c": "cut o"#) == #"{"a": "x", "b": ["p"]}"#)
        #expect(closed(#"{"a": "x, y", "b": "z"#) == #"{"a": "x, y"}"#, "a comma inside a string is not a cut point")
        #expect(closed(#"{"a": "he said \"hi, there\" and"#) == nil, "nothing complete yet")
        #expect(closed(#"{"a": "cut o"#) == nil)
        #expect(closed(#"```json {"a": 1, "b": 2}"#) == #"{"a": 1, "b": 2}"#, "it was complete after all")
        #expect(closed("no json") == nil)
        #expect(closed(#"{"a": [1, 2], "b": {"c": [1, 2, 3"#) == #"{"a": [1, 2]}"#, "deeper than two brackets: the cut is made higher up")
        let kept = closed(#"{"a": "x", "b": ["p", "q", "r"#)!
        #expect((try? JSONSerialization.jsonObject(with: Data(kept.utf8))) is [String: Any])
    }

    @Test func aBlockExtractThatIsCutOffAndCannotBeSplitIsLeftOutNotPassedOn() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<120).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, call in
            let last = messages.last?.content ?? ""
            if last.contains("ONLY one block") {
                // The very first block is always cut off, however small it gets.
                if messages.map(\.content).joined().contains("item 0\n") { return ScriptedChat.reply(#"{"summary": "TRUNCATEDBLOCK"#, finish: .length) }
                return ScriptedChat.reply(Self.extract(messages))
            }
            return ScriptedChat.reply(Self.finalReply)
        }
        let outcome = try await run(f, id, chat: chat)
        #expect(outcome == .succeeded)
        let final = try #require(chat.calls.last)
        #expect(!final.text.contains("TRUNCATEDBLOCK"), "half an object never reaches the final request")
    }

    @Test func theDiagnosticsCountTheBlocksThatLeftNothingInTheMinutes() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<120).map { "\(Self.sentence) item \($0)" })
        // The first block is always cut off; the others are fine.
        let chat = ScriptedChat { messages, _, _ in
            if messages.last?.content.contains("ONLY one block") == true {
                return messages.map(\.content).joined().contains("item 0\n") ? ScriptedChat.reply(#"{"summary": "cut"#, finish: .length) : ScriptedChat.reply(Self.extract(messages))
            }
            return ScriptedChat.reply(Self.finalReply)
        }
        let events = EventLog()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        let d = try #require(await service.lastMinutesDiagnostics)
        #expect(d.blocks >= 4 && d.blocksOmitted >= 1 && d.blocksUnreadable == 0, "\(d.line)")
        #expect(d.line.contains("omitted \(d.blocksOmitted)"))
        #expect(d.isIncomplete == ((d.blocksOmitted + d.blocksUnreadable) * 4 > d.blocks))
        // One minutes request for a short meeting has no blocks at all.
        #expect(MinutesDiagnostics(ValidatedMinutes()).blocks == 0 && !MinutesDiagnostics(ValidatedMinutes()).isIncomplete)
        var many = MinutesDiagnostics(ValidatedMinutes())
        many.blocks = 8
        many.blocksOmitted = 2
        #expect(!many.isIncomplete)
        many.blocksUnreadable = 1
        #expect(many.isIncomplete)
    }

    @Test func aLargeWindowKeepsItsExtractsAndWritesTheWholeMinutesItself() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<12).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, call in
            if call == 1 { throw LLMError.contextLengthExceeded(message: "n_ctx") }
            if messages.map(\.content).joined().contains("<<<BLOCK") { return ScriptedChat.reply(Self.extract(messages)) }
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let events = EventLog()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.kind == .minutes } })
        let final = chat.calls.last { !$0.text.contains("This is the end of the meeting") }
        #expect(final?.text.contains("<<<EXTRACTS") == true && final?.text.contains("Combine them into a single set of minutes") == true)
    }

    // MARK: The digest

    @Test func theDigestKeepsItemsOnceAndSkipsWhatItCannotRead() throws {
        let one = #"{"summary": "A.", "topics": ["x"], "decisions": [{"text": "Keep it", "seg": 1, "quote": "keep it please"}], "tasks": [{"text": "Send", "seg": 1, "quote": "send it please"}], "entities": [{"mention": "Ana", "id": 3, "seg": 1}], "open_questions": ["Q?"]}"#
        let two = #"{"summary": "B.", "decisions": [{"text": "keep IT", "seg": 2, "quote": "keep it please"}, {"text": "Move", "seg": 2, "quote": "move it please"}], "entities": [{"mention": "Ana", "id": 3, "seg": 1}]}"#
        let digest = MinutesDigest(extracts: [one, #"{"summary": "cut o"#, two, "not json at all"])
        #expect(digest.unreadable == 2)
        #expect(digest.decisions.compactMap { $0["text"] as? String } == ["Keep it", "Move"], "a repeat (case-insensitive) is kept once")
        #expect(digest.tasks.count == 1 && digest.entities.count == 1)
        let merged = try #require(digest.combine(#"{"title": "T", "summary": "S", "topics": [], "open_questions": [], "decisions": [{"text": "invented"}]}"#))
        let object = try #require(JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
        #expect((object["decisions"] as? [[String: Any]])?.count == 2, "what the model wrote for the lists is replaced")
        #expect(object["title"] as? String == "T")
        #expect(digest.combine("no object here") == nil)
    }

    @Test func theDigestAlwaysFitsWhatIsLeftOfTheWindow() {
        let extracts = (0..<40).map { i in
            #"{"summary": "\#(String(repeating: "The team discussed point \(i) at length. ", count: 12))", "topics": ["a \#(i)", "b", "c", "d"], "decisions": [{"text": "Decision number \#(i) about the budget line", "seg": \#(i), "quote": "quote \#(i)"}], "tasks": [{"text": "Task \#(i)", "seg": \#(i), "quote": "q \#(i)"}], "open_questions": ["Question \#(i)?"]}"#
        }
        let digest = MinutesDigest(extracts: extracts)
        for budget in [3_000, 1_500, 800, 400, 200] {
            let message = digest.message(tokens: budget)
            #expect(PromptText.tokens(message.content) <= budget, "\(budget): \(PromptText.tokens(message.content))")
            #expect(message.content.hasPrefix("<<<NOTES ON THE BLOCKS OF THE MEETING"))
        }
        // With room, everything is there; with less, the lists go before the summaries do.
        let full = digest.message(tokens: 100_000).content
        #expect(full.contains("Decided: Decision number 0") && full.contains("Tasks: Task 0") && full.contains("Topics: a 0") && full.contains("Open: Question 0?"))
        let tight = digest.message(tokens: 7_000).content
        #expect(!tight.contains("Decided:") && tight.contains("Summary:"))
    }
}
