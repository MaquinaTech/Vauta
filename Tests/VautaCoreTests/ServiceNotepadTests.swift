// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Service: expanding the user's notes")
struct ServiceNotepadTests {
    private let lines = ["Ana said we will raise the Q3 budget by 10% if hiring waits",
                         "Luis agreed but wants the numbers from finance first",
                         "Then we talked about the offsite in Lisbon in May"]

    /// A meeting with enough text, a note typed at 12 s and a scripted model that expands notes and writes minutes.
    private func setup(context: Int = 32_768, onDevice: Bool = false, supports: (@Sendable (Locale) -> Bool)? = nil,
                       notes: [String] = ["Q3 budget +10%"], handler: ScriptedChat.Handler? = nil)
        async throws -> (KnowledgeFixture, LLMService, ScriptedChat, Int64, [Int64]) {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(lines)
        var ids: [Int64] = []
        for (i, text) in notes.enumerated() { ids.append(try await f.store.addNote(id, at: 12 + Double(i), text: text)) }
        let chat = ScriptedChat(handler ?? { messages, _, _ in
            ScriptedChat.reply(ScriptedChat.isNoteRequest(messages) ? ScriptedChat.notesJSON(messages) : ScriptedChat.minutesJSON(messages))
        })
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: context, onDevice: onDevice, supports: supports))
        return (f, service, chat, id, ids)
    }

    private func runMinutes(_ f: KnowledgeFixture, _ service: LLMService, _ id: Int64) async throws -> [LLMService.JobEvent] {
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        return events.events
    }

    // MARK: Live

    @Test func theLivePassUsesTheFastModelAndStoresAVerifiedExpansion() async throws {
        let (f, service, chat, id, notes) = try await setup()
        #expect(try await service.expandNoteLive(meetingID: id, noteID: notes[0]) == .done)
        let call = try #require(chat.calls.first)
        #expect(call.options.model == .fast && call.options.purpose == .notes && !call.options.thinking)
        #expect(call.text.contains("- Q3 budget +10%") && call.text.contains("<<<TRANSCRIPT"))
        let row = try #require(try await f.store.noteRows(id).first)
        #expect(row.expansion?.pass == .live && row.expansion?.state == .done && row.expansion?.sentences.count == 1)
        #expect(row.expansion?.sentences[0].cites.count == 1)
        #expect(row.note.text == "Q3 budget +10%", "the user's words are untouched")
    }

    @Test func theWindowIncludesTheTwoPreviousNotesAsContextOnly() async throws {
        let (f, service, chat, id, notes) = try await setup(notes: ["first one", "second one", "third one", "Q3 same"])
        _ = try await service.expandNoteLive(meetingID: id, noteID: notes[3])
        let text = try #require(chat.calls.first?.text)
        #expect(text.contains("Earlier notes by the user, for context only"))
        #expect(text.contains("- second one") && text.contains("- third one") && !text.contains("- first one"))
        _ = f
    }

    @Test func aFailedLiveTryKeepsTheNotePendingWithItsCode() async throws {
        let (f, service, _, id, notes) = try await setup(handler: { _, _, _ in throw LLMError.network("offline") })
        await #expect(throws: LLMError.self) { try await service.expandNoteLive(meetingID: id, noteID: notes[0]) }
        let e = try #require(try await f.store.expansion(of: notes[0]))
        #expect(e.state == .pending && e.errorCode == "network")
    }

    @Test func aLanguageTheModelCannotWriteIsSaidNotGuessed() async throws {
        let (f, service, chat, id, notes) = try await setup(onDevice: true, supports: { _ in false })
        await #expect(throws: LLMError.unsupportedLanguage) { try await service.expandNoteLive(meetingID: id, noteID: notes[0]) }
        #expect(chat.calls.isEmpty)
        #expect(try await f.store.expansion(of: notes[0])?.errorCode == "unsupported_language")
    }

    @Test func theOnDeviceModelGetsOneNoteWithoutThinkingAndNothingElse() async throws {
        let (f, service, chat, id, notes) = try await setup(context: 4_096, onDevice: true, notes: ["one", "two", "three"])
        _ = try await runMinutes(f, service, id)
        let noteCalls = chat.calls.filter { ScriptedChat.isNoteRequest($0.messages) }
        #expect(noteCalls.count == 3, "one note per request")
        #expect(noteCalls.allSatisfy { !$0.options.thinking && $0.options.model == .deep && $0.options.maxTokens == 320 })
        #expect(noteCalls.allSatisfy { PromptText.tokens($0.messages) + $0.options.maxTokens <= 4_096 })
        _ = notes
    }

    // MARK: The final pass

    @Test func theFinalPassRunsBeforeTheMinutesWithTheMainModelAndFeedsThem() async throws {
        let (f, service, chat, id, notes) = try await setup()
        try await f.store.addLiveNotes(id, at: 20, json: #"{"puntos":[{"texto":"Budget stays","seg":null}]}"#)
        let events = try await runMinutes(f, service, id)
        #expect(events.last?.outcome == .succeeded)
        let order = chat.calls.map { ScriptedChat.isNoteRequest($0.messages) ? "note" : "minutes" }
        #expect(order == ["note", "minutes"])
        try #require(chat.calls.count >= 2)
        #expect(chat.calls[0].options.model == .deep && chat.calls[0].options.purpose == .notes && chat.calls[0].options.thinking)
        let minutes = chat.calls[1].text
        #expect(minutes.contains("PRIORITY") && minutes.contains("\"Q3 budget +10%\" → "), "the user's words, then what the transcript says")
        #expect(minutes.contains("[S"), "with the segments it cites")
        #expect(try await f.store.expansion(of: notes[0])?.pass == .closing)
        // The user's headline is the first topic, word for word.
        #expect(try await f.store.card(id)?.topics.first == "Q3 budget +10%")
    }

    @Test func aSmallWindowSendsOnlyTheUsersWordsToTheMinutes() async throws {
        let (f, service, chat, id, _) = try await setup(context: 4_096, onDevice: true)
        _ = try await runMinutes(f, service, id)
        let minutes = try #require(chat.calls.last { !ScriptedChat.isNoteRequest($0.messages) && !$0.text.contains("actually decided in the transcript") }).text
        #expect(minutes.contains("PRIORITY") && minutes.contains("[00:12] \"Q3 budget +10%\""))
        #expect(!minutes.contains("→"), "no expansions on the small window")
    }

    @Test func aFailingNoteDoesNotFailTheMinutes() async throws {
        let (f, service, chat, id, notes) = try await setup(handler: { messages, _, _ in
            ScriptedChat.isNoteRequest(messages) ? ScriptedChat.reply("not json at all") : ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        })
        let events = try await runMinutes(f, service, id)
        #expect(events.last?.outcome == .succeeded)
        let e = try #require(try await f.store.expansion(of: notes[0]))
        #expect(e.state == .failed && e.errorCode == "invalid_response")
        #expect(chat.calls.filter { ScriptedChat.isNoteRequest($0.messages) }.count == 2, "one repair try")
        #expect(chat.calls.last?.text.contains("PRIORITY") == true, "the minutes still get the user's words")
    }

    @Test func theFinalPassRedoesLiveResultsButNeverEditedOrDismissedNotes() async throws {
        let (f, service, chat, id, notes) = try await setup(notes: ["live one", "edited one", "dismissed one", "final one"])
        let key = { TextKeys.norm($0) }
        let old = NoteExpansion.Sentence(text: "Old.", cites: [], quote: "")
        try await f.store.saveExpansion(noteID: notes[0], pass: .live, outcome: .sentences([old]), sourceKey: key("live one"))
        try await f.store.saveExpansion(noteID: notes[1], pass: .live, outcome: .sentences([old]), sourceKey: key("edited one"))
        try await f.store.editExpansion(noteID: notes[1], text: "Mine.")
        try await f.store.dismissExpansion(noteID: notes[2])
        try await f.store.saveExpansion(noteID: notes[3], pass: .closing, outcome: .sentences([old]), sourceKey: key("final one"))
        _ = try await runMinutes(f, service, id)
        let sent = chat.calls.filter { ScriptedChat.isNoteRequest($0.messages) }.map(\.text).joined()
        #expect(sent.contains("live one") && !sent.contains("- edited one") && !sent.contains("- dismissed one") && !sent.contains("- final one"))
        #expect(try await f.store.expansion(of: notes[0])?.pass == .closing)
        #expect(try await f.store.expansion(of: notes[1])?.sentences.map(\.text) == ["Mine."])
        #expect(try await f.store.expansion(of: notes[2])?.state == .dismissed)
        #expect(try await f.store.expansion(of: notes[3])?.sentences.map(\.text) == ["Old."])
        // Regenerating the minutes later redoes nothing that is done.
        let before = chat.calls.count
        _ = try await runMinutes(f, service, id)
        #expect(chat.calls.dropFirst(before).filter { ScriptedChat.isNoteRequest($0.messages) }.isEmpty)
    }

    @Test func aLargeWindowAsksForSeveralConsecutiveNotesAtOnce() async throws {
        let (f, service, chat, id, notes) = try await setup(notes: ["alpha note", "beta note", "gamma note"])
        _ = try await runMinutes(f, service, id)
        let noteCalls = chat.calls.filter { ScriptedChat.isNoteRequest($0.messages) }
        try #require(noteCalls.count == 1)
        #expect(noteCalls[0].text.contains("<<<NOTE 3\n- gamma note"))
        for n in notes { #expect(try await f.store.expansion(of: n)?.state == .done) }
    }

    @Test func anExpandAgainWhileRecordingIsStoredAsLiveSoTheFinalPassRedoesIt() async throws {
        let (f, service, _, id, notes) = try await setup()
        await service.setRecording(true, meetingID: id)
        #expect(try await service.expandNote(noteID: notes[0]) == .done)
        let e = try #require(try await f.store.expansion(of: notes[0]))
        #expect(e.pass == .live, "provisional speakers: the final pass writes it again")
        #expect(try await f.store.notesNeedingExpansion(id, includingLive: true).map(\.id) == notes)
        _ = f
    }

    // MARK: After the meeting

    @Test func aNoteTypedAfterTheMeetingUsesTheMeetingsSearchWhenItDoesNotFit() async throws {
        let f = try KnowledgeFixture()
        let sentence = "We went through the quarterly zzharbor budget line by line and agreed on next steps"
        let id = try await f.meeting((0..<200).map { "\(sentence) (\($0))" })
        let note = try await f.store.addNote(id, at: 0, text: "zzharbor budget", addedAfter: true)
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.notesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        #expect(try await service.expandNote(noteID: note) == .done)
        let call = try #require(chat.calls.first)
        #expect(call.text.contains("<<<EXCERPTS FROM YOUR MEETINGS") && !call.text.contains("<<<TRANSCRIPT"))
        #expect(PromptText.tokens(call.messages) + call.options.maxTokens <= 4_096)
        #expect(try await f.store.expansion(of: note)?.pass == .manual)
    }

    @Test func japaneseSearchPassagesFitTheFourKWindow() async throws {
        let f = try KnowledgeFixture()
        let sentence = "四半期の予算会議では各部署の費用を一つずつ確認し次の手順について合意しました"
        let id = try await f.meeting((0..<300).map { "\(sentence)\($0)" }, locale: "ja-JP")
        let note = try await f.store.addNote(id, at: 0, text: "予算会議", addedAfter: true)
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.notesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        #expect(try await service.expandNote(noteID: note) == .done)
        let call = try #require(chat.calls.first)
        #expect(call.text.contains("<<<EXCERPTS FROM YOUR MEETINGS"))
        #expect(PromptText.tokens(call.messages) + call.options.maxTokens <= 4_096, "the passages are measured, not assumed")
    }

    @Test func aSearchRetryThatErrorsKeepsTheNotesAlreadyExpandedAndNotFound() async throws {
        let (f, service, chat, id, notes) = try await setup(notes: ["first note", "second note"], handler: { messages, _, call in
            guard ScriptedChat.isNoteRequest(messages) else { return ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
            guard call == 1, let (seg, text) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("not json at all") }
            let quote = String(text.prefix(30))
            return ScriptedChat.reply(#"{"notes": [{"n": 1, "sentences": [{"text": "Said: \#(quote).", "seg": [\#(seg)], "quote": "\#(quote)"}]}, {"n": 2, "sentences": []}]}"#)
        })
        let events = try await runMinutes(f, service, id)
        #expect(events.last?.outcome == .succeeded)
        #expect(try await f.store.expansion(of: notes[0])?.state == .done, "a verified expansion survives the other note's failing retry")
        #expect(try await f.store.expansion(of: notes[1])?.state == .notFound, "the retry's error does not turn not-found into failed")
        _ = chat
    }

    @Test func aNoteThatWaitedIsExpandedFromTheTalkAroundItNotFromNow() async throws {
        let f = try KnowledgeFixture()
        let filler = String(repeating: "and we kept discussing the details of the plan ", count: 6)
        let id = try await f.meeting((0..<60).map { "Line \($0) \(filler)" })
        let note = try await f.store.addNote(id, at: 12, text: "plan details")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.notesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        #expect(try await service.expandNoteLive(meetingID: id, noteID: note) == .done)
        let text = try #require(chat.calls.first).text
        #expect(text.contains("Line 1 ") && !text.contains("Line 55 "), "six minutes later the window is still the one around the note")
    }

    @Test func aNoteTypedWhileTheMinutesAreBeingWrittenDoesNotRestartThem() async throws {
        let gate = EmbedGate()
        await gate.close()
        let (f, service, chat, id, _) = try await setup(handler: { messages, _, _ in
            if ScriptedChat.isNoteRequest(messages) { return ScriptedChat.reply(ScriptedChat.notesJSON(messages)) }
            await gate.wait()
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        })
        let late = try await f.store.addNote(id, at: 0, text: "offsite Lisbon", addedAfter: true)
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { await gate.held > 0 })
        let manual = Task { try await service.expandNote(noteID: late) }
        try await Task.sleep(for: .milliseconds(150))
        await gate.release()
        #expect(await eventually { events.events.contains { $0.kind == .minutes } })
        #expect(events.events.last?.outcome == .succeeded)
        #expect(chat.calls.filter { !ScriptedChat.isNoteRequest($0.messages) }.count == 1, "the minutes request was not cancelled and sent again")
        #expect(try await manual.value == .done)
    }

    @Test func backfillExpandsTheNotesAFinishedMeetingStillHasUnexpanded() async throws {
        let (f, service, chat, id, notes) = try await setup(notes: ["done one", "failed one"])
        _ = try await runMinutes(f, service, id)
        // Later (a new launch): one note failed for good, another was never tried.
        let first = try #require(try await f.store.expansion(of: notes[1]))
        var failed = first
        failed.state = .failed; failed.sentences = []; failed.errorCode = "invalid_response"
        try await f.store.restoreExpansion(noteID: notes[1], to: failed)
        let fresh = try await f.store.addNote(id, at: 30, text: "never tried", addedAfter: true)
        let relaunched = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 32_768))
        let before = chat.calls.count
        await relaunched.backfill()
        #expect(await eventually { (try? await f.store.expansion(of: fresh))?.state == .done })
        #expect(try await f.store.expansion(of: notes[1])?.state == .done)
        #expect(try await f.store.expansion(of: notes[0])?.state == .done)
        let sent = chat.calls.dropFirst(before)
        #expect(sent.allSatisfy { ScriptedChat.isNoteRequest($0.messages) } && sent.count <= 2,
                "no minutes written, and the finished note is not redone")
    }

    @Test func aMeetingFromBeforeTheNotepadIsLeftAlone() async throws {
        let (f, service, chat, id, notes) = try await setup(notes: ["old note"])
        _ = try await runMinutes(f, service, id)
        try await f.store.restoreExpansion(noteID: notes[0], to: nil)   // as if the note were from before the notepad
        let before = chat.calls.count
        await service.backfill()
        try await Task.sleep(for: .milliseconds(300))
        #expect(chat.calls.count == before)
    }

    @Test func aNoteTypedAfterAShortMeetingGetsTheWholeTranscript() async throws {
        let (f, service, chat, id, _) = try await setup()
        let late = try await f.store.addNote(id, at: 0, text: "offsite Lisbon", addedAfter: true)
        #expect(try await service.expandNote(noteID: late) == .done)
        #expect(chat.calls.last?.text.contains("<<<TRANSCRIPT") == true)
        #expect(chat.calls.last?.options.model == .deep)
    }

    @Test func whenTheWindowFindsNothingTheSearchIsTriedOnce() async throws {
        let f = try KnowledgeFixture()
        let sentence = "We went through the quarterly zzharbor budget line by line and agreed on next steps"
        let id = try await f.meeting((0..<200).map { "\(sentence) (\($0))" })
        let note = try await f.store.addNote(id, at: 5, text: "zzharbor budget")
        let chat = ScriptedChat { messages, _, _ in
            let found = messages.contains { $0.content.contains("<<<EXCERPTS") }
            return ScriptedChat.reply(found ? ScriptedChat.notesJSON(messages) : #"{"sentences": []}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        #expect(try await service.expandNote(noteID: note) == .done)
        #expect(chat.calls.count == 2)
    }

    @Test func expandAgainOnAnEditedExpansionKeepsTheEditToGoBackTo() async throws {
        let (f, service, _, id, notes) = try await setup()
        try await f.store.saveExpansion(noteID: notes[0], pass: .live, outcome: .sentences([.init(text: "Model.")]), sourceKey: TextKeys.norm("Q3 budget +10%"))
        try await f.store.editExpansion(noteID: notes[0], text: "Mine.")
        #expect(try await service.expandNote(noteID: notes[0], replacingEdited: true) == .done)
        #expect(try await f.store.expansion(of: notes[0])?.previous?.sentences.map(\.text) == ["Mine."])
        _ = id
    }

    // MARK: Later passes

    @Test func regeneratingTheMinutesRedoesOnlyStaleFailedAndNotFoundNotes() async throws {
        let (f, service, chat, id, notes) = try await setup(notes: ["current one", "changed one", "empty one", "broken one"])
        let key = { TextKeys.norm($0) }
        let sentence = NoteExpansion.Sentence(text: "Said.", cites: [], quote: "")
        try await f.store.saveExpansion(noteID: notes[0], pass: .closing, outcome: .sentences([sentence]), sourceKey: key("current one"))
        try await f.store.saveExpansion(noteID: notes[1], pass: .closing, outcome: .sentences([sentence]), sourceKey: key("an older wording"))
        try await f.store.saveExpansion(noteID: notes[2], pass: .closing, outcome: .sentences([]), sourceKey: key("empty one"))
        try await f.store.saveExpansion(noteID: notes[3], pass: .closing, outcome: .failed(code: "server"), sourceKey: key("broken one"))
        _ = try await runMinutes(f, service, id)
        let sent = chat.calls.filter { ScriptedChat.isNoteRequest($0.messages) }.map(\.text).joined()
        #expect(sent.contains("changed one") && sent.contains("empty one") && sent.contains("broken one"))
        #expect(sent.contains("<<<NOTE 3\n") && !sent.contains("<<<NOTE 4\n") && !sent.contains("<<<NOTE 1\n- current one"),
                "three notes are asked for; the current result is not asked for again (it can only appear as an earlier note, for context)")
    }

    @Test func aNoteTheUserRemovedIsNeverWrittenAgainByAPassEvenAfterTheyFixATypo() async throws {
        let (f, service, chat, id, notes) = try await setup()
        try await f.store.dismissExpansion(noteID: notes[0])
        try await f.store.updateNote(notes[0], text: "Q3 budget +12%")
        // The automatic passes leave it alone; only the user's own "Expand Again" writes it.
        #expect(try await service.expandNote(noteID: notes[0]) == .dismissed)
        _ = try await runMinutes(f, service, id)
        #expect(try await f.store.expansion(of: notes[0])?.state == .dismissed && chat.calls.filter { ScriptedChat.isNoteRequest($0.messages) }.count <= 1)
        #expect(try await service.expandNote(noteID: notes[0], replacingEdited: true) == .done)
    }

    // MARK: Live notes and the user's notes

    @Test func theLivePassGetsTheUsersNotesButOnAFourKWindowFewShortOnesAndStillFits() async throws {
        let f = try KnowledgeFixture()
        let sentence = "We went through the quarterly zzharbor budget line by line and agreed on the next steps for the whole team"
        let id = try await f.meeting((0..<120).map { "\(sentence) (\($0))" })
        let long = String(repeating: "a long note about the quarterly budget and hiring plans ", count: 6)
        for i in 0..<12 { try await f.store.addNote(id, at: Double(i), text: "n\(i) " + long) }
        let chat = ScriptedChat { messages, _, _ in
            guard let (seg, _) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(#"{"points": [{"text": "Budget", "seg": \#(seg)}], "decisions": [], "tasks": []}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setRecording(true, meetingID: id)
        _ = try await service.liveNotes(meetingID: id, at: 100)
        let call = try #require(chat.calls.first)
        let instruction = try #require(call.messages.last?.content)
        #expect(instruction.contains("The user already wrote these notes") && instruction.contains("n11 ") && !instruction.contains("n6 "),
                "the latest five, not twelve")
        #expect(instruction.contains(String(long.prefix(60))) && !instruction.contains(String(long.prefix(100))), "cut to 80 characters each")
        #expect(PromptText.tokens(call.messages) + call.options.maxTokens + ContextBudget(contextTokens: 4_096).safety <= 4_096)
    }

    @Test func aLargeWindowKeepsTwelveNotesOfTwoHundredCharacters() {
        let big = ContextBudget(contextTokens: 32_768), small = ContextBudget(contextTokens: 4_096)
        #expect(big.liveUserNotes.count == 12 && big.liveUserNotes.characters == 200)
        #expect(small.liveUserNotes.count == 5 && small.liveUserNotes.characters == 80)
        let notes = (0..<12).map { "note \($0) " + String(repeating: "x", count: 300) }
        let block = VautaPrompts.liveUserNotesBlock(notes, count: 5, characters: 80)
        #expect(block.split(separator: "\n").count == 6 && block.contains("note 11") && !block.contains("note 6"))
    }
}
