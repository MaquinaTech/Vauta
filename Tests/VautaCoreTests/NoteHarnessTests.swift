// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Notepad harness: prompt, output budget and salvage of a cut reply")
struct NoteHarnessTests {
    private let language = OutputLanguage(Locale(identifier: "en-US"))

    @Test func theSwitchParsesAndNamesItsParts() {
        #expect(NoteHarness.parse("old") == .legacy && NoteHarness.parse("new") == .shipped)
        #expect(NoteHarness.parse("prompt,salvage") == [.prompt, .salvage])
        #expect(NoteHarness.parse("new,relevance") == NoteHarness.shipped && NoteHarness.parse("repair") == .repair)
        #expect(NoteHarness.parse("nonsense") == nil)
        #expect(NoteHarness.shipped.names == "prompt+budget+salvage+repair+relevance" && NoteHarness.legacy.names == "legacy")
        #expect(NoteHarnessRelease.harness(integrated: false) == .legacy && NoteHarnessRelease.harness(integrated: true) == .legacy,
                "the app keeps the expansion it had until the blind comparison says otherwise")
    }

    @Test func theTightPromptAsksForAShortQuoteAndShowsEmptyShapes() {
        let tight = VautaPrompts.noteInstruction(["Q3 budget"], maxSentences: 3, language: language, harness: .prompt).content
        #expect(tight.contains("4 to 15 words") && tight.contains(#""text": """#) && !tight.contains("…"))
        #expect(tight.contains(#"{"sentences": []}"#) && tight.contains("at most 25 words") && tight.contains("not S10"))
        let old = VautaPrompts.noteInstruction(["Q3 budget"], maxSentences: 3, language: language).content
        #expect(!old.contains("4 to 15 words") && old.contains("…"), "the legacy prompt is unchanged")
        #expect(old.contains("Every sentence cites the segments that support it and copies a verbatim quote from one of them."))
    }

    @Test func theOutputLimitFollowsTheRoomOnlyOnTheSmallWindow() {
        let small = ContextBudget(contextTokens: 4_096), large = ContextBudget(contextTokens: 32_768)
        #expect(small.noteOutputLimit(.legacy, promptTokens: 1_000) == 320)
        #expect(small.noteOutputLimit(.budget, promptTokens: 1_000) == 700, "capped at the ceiling")
        #expect(small.noteOutputLimit(.budget, promptTokens: nil) == 700)
        let tightRoom = small.noteOutputLimit(.budget, promptTokens: 3_500)
        #expect(tightRoom == 320, "never under the old limit")
        let some = small.noteOutputLimit(.budget, promptTokens: 4_096 - small.safety - 500)
        #expect(some == 500)
        #expect(large.noteOutputLimit(.shipped, promptTokens: 1_000) == large.noteOutput, "a large window is untouched")
    }

    @Test func segmentTagsAreMadeNumbersOutsideTheStringsOnly() {
        let raw = #"```json\n{"sentences": [{"text": "See S10 and [S11]", "seg": [S10, S11], "quote": "as S12 said", "differs": false}]}\n```"#
        let fixed = NoteReply.repaired(raw)
        #expect(fixed.contains(#""seg": [10, 11]"#), "the tags outside strings become numbers")
        #expect(fixed.contains("See S10 and [S11]") && fixed.contains("as S12 said"), "strings are left as they are")
        #expect(NoteReply.repaired(#"{"seg": [s3]}"#) == #"{"seg": [3]}"#)
        #expect(NoteReply.repaired(#"{"a": "x\"S1", "seg": [S2]}"#) == #"{"a": "x\"S1", "seg": [2]}"#, "an escaped quote does not end the string")
        #expect(NoteReply.repaired(#"{"seg": [12, 13], "ok": true}"#) == #"{"seg": [12, 13], "ok": true}"#)
    }

    @Test func aDiffersWrittenIntoTheTextIsRemovedFromIt() {
        #expect(NoteReply.tidied("Ana said no. differs: true") == "Ana said no.")
        #expect(NoteReply.tidied("Ana said no (differs: false)") == "Ana said no.")
        #expect(NoteReply.tidied("Me dijo que no hay tres proveedores. seg: 101") == "Me dijo que no hay tres proveedores.")
        #expect(NoteReply.tidied("Ana differs with Luis about the budget.") == "Ana differs with Luis about the budget.")
    }

    @Test func aReplyWithSegmentTagsIsReadOnlyWithTheRepair() throws {
        let segment = CitableSegment(id: 10, channel: .others, start: 5, text: "We will raise the Q3 budget by 10% if hiring waits", speaker: nil)
        let raw = #"{"sentences": [{"text": "Budget goes up. differs: true", "seg": [S10], "quote": "raise the Q3 budget by 10%", "differs": false}]}"#
        let plain = VautaPrompts.NoteCheck(sent: [10: segment], maxSentences: 3)
        #expect(throws: LLMError.self) { try VautaPrompts.validateNoteExpansion(raw, check: plain) }
        let tidy = VautaPrompts.NoteCheck(sent: [10: segment], maxSentences: 3, tidy: true)
        let out = try VautaPrompts.validateNoteExpansion(NoteReply.repaired(raw), check: tidy)
        #expect(out.map(\.text) == ["Budget goes up."] && out[0].cites.map(\.seg) == [10])
    }

    @Test func aSentenceAboutSomethingMuchEarlierThanTheNoteIsDropped() {
        let note = MeetingNote(id: 1, meetingID: 1, t: 300, text: "budget Q3 +10%")
        func sentence(_ text: String, at times: [Double]) -> NoteExpansion.Sentence {
            NoteExpansion.Sentence(text: text, cites: times.enumerated().map { .init(seg: Int64($0.offset), t: $0.element) }, quote: "x")
        }
        let kept = NoteReply.relevant([sentence("Far before.", at: [10]),
                                       sentence("Far before, one close line.", at: [10, 290]),
                                       sentence("Fifty seconds before.", at: [250]),
                                       sentence("Just inside.", at: [225]),
                                       sentence("Just outside.", at: [224]),
                                       sentence("After the note.", at: [340]),
                                       sentence("No citation.", at: [])], to: note)
        #expect(kept.map(\.text) == ["Far before, one close line.", "Fifty seconds before.", "Just inside.", "After the note."])
        let late = MeetingNote(id: 2, meetingID: 1, t: 300, text: "budget", addedAfter: true)
        #expect(NoteReply.relevant([sentence("Unrelated.", at: [10])], to: late).count == 1, "a note typed after the meeting has no time of its own")
    }

    @Test func theTightSchemaBoundsTheSentencesAndTheQuote() {
        #expect(OutputSchemas.noteSingle(tight: true) != OutputSchemas.noteSingle())
    }

    // MARK: A cut reply

    private func setup(_ harness: NoteHarness, cut: String) async throws -> (KnowledgeFixture, LLMService, ScriptedChat, Int64, Int64) {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["Ana said we will raise the Q3 budget by 10% if hiring waits",
                                      "Luis agreed but wants the numbers from finance first",
                                      "Then we talked about the offsite in Lisbon in May"])
        let note = try await f.store.addNote(id, at: 12, text: "Q3 budget +10%")
        let chat = ScriptedChat({ messages, _, _ in
            guard let (sid, _) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(cut.replacingOccurrences(of: "SID", with: "\(sid)"), finish: .length)
        })
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setNoteHarness(harness)
        return (f, service, chat, id, note)
    }

    private let cutReply = #"{"sentences": [{"text": "Ana proposes raising the Q3 budget by 10%.", "seg": [SID], "quote": "raise the Q3 budget by 10%", "differs": false}, {"text": "Luis wants the nu"#

    @Test func aCutReplyKeepsItsFinishedSentences() async throws {
        let (f, service, chat, id, note) = try await setup(.shipped, cut: cutReply)
        #expect(try await service.expandNoteLive(meetingID: id, noteID: note) == .done)
        let e = try #require(try await f.store.expansion(of: note))
        #expect(e.sentences.map(\.text) == ["Ana proposes raising the Q3 budget by 10%."])
        #expect(chat.calls.count == 1, "no second try: the finished sentence is used")
        let call = try #require(chat.calls.first)
        #expect(call.options.maxTokens > 320 && PromptText.tokens(call.messages) + call.options.maxTokens <= 4_096)
        #expect(call.text.contains("4 to 15 words"))
    }

    @Test func aCutReplyWithSegmentTagsIsSalvagedToo() async throws {
        let tagged = cutReply.replacingOccurrences(of: #""seg": [SID]"#, with: #""seg": [SSID]"#)
        let (f, service, _, id, note) = try await setup(.shipped, cut: tagged)
        #expect(try await service.expandNoteLive(meetingID: id, noteID: note) == .done)
        _ = f
    }

    @Test func aCutReplyWhoseFinishedSentencesAreTooOldForTheNoteIsNothingFoundNotAFailure() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["Ana said we will raise the Q3 budget by 10% if hiring waits",
                                      "Luis agreed but wants the numbers from finance first"])
        let note = try await f.store.addNote(id, at: 150, text: "offsite Lisbon")
        let chat = ScriptedChat({ messages, _, _ in
            guard let (sid, _) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            let cut = #"{"sentences": [{"text": "Ana proposes raising the Q3 budget.", "seg": [\#(sid)], "quote": "raise the Q3 budget by 10%", "differs": false}, {"text": "Luis wants the nu"#
            return ScriptedChat.reply(cut, finish: .length)
        })
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setNoteHarness(.shipped)
        // The sentence cites a line 150 s before the note and is dropped, and that is the answer (no second try).
        #expect(try await service.expandNoteLive(meetingID: id, noteID: note) == .notFound)
        #expect(chat.calls.count == 1)
        _ = f
    }

    @Test func withoutTheHarnessACutReplyStillFails() async throws {
        let (f, service, _, id, note) = try await setup(.legacy, cut: cutReply)
        await #expect(throws: LLMError.self) { try await service.expandNoteLive(meetingID: id, noteID: note) }
        _ = f   // the store lives as long as the test
    }

    @Test func aCutReplyWithNothingFinishedFailsAsBefore() async throws {
        let (f, service, _, id, note) = try await setup(.shipped, cut: #"{"sentences": [{"text": "Ana prop"#)
        await #expect(throws: LLMError.self) { try await service.expandNoteLive(meetingID: id, noteID: note) }
        _ = f   // the store lives as long as the test
    }

    @Test func aFinishedSentenceThatFailsTheVerifierIsNotKept() async throws {
        let bad = #"{"sentences": [{"text": "Invented.", "seg": [SID], "quote": "words that are not there", "differs": false}, {"text": "Luis wants"#
        let (f, service, _, id, note) = try await setup(.shipped, cut: bad)
        await #expect(throws: LLMError.self) { try await service.expandNoteLive(meetingID: id, noteID: note) }
        _ = f   // the store lives as long as the test
    }
}
