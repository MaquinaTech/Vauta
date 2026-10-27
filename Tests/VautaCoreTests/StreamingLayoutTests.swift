// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The integrated model's prompt layout: one prefix for every task, the rules in it, the question alone at the end; the cold-read
/// fallback; and the progress of reading.
@Suite("Prompts: the streaming layout")
struct StreamingLayoutTests {
    static let lines = ["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is", "Ana will send the numbers on Friday"]

    // MARK: Lines

    @Test func aLineNeverChangesWhenTheSpeakerGetsAName() {
        let plain = CitableSegment(id: 12, channel: .others, start: 192, text: "We keep the budget", speaker: SpeakerTag(id: 4, ordinal: 2))
        let named = CitableSegment(id: 12, channel: .others, start: 192, text: "We keep the budget", speaker: SpeakerTag(id: 4, ordinal: 2, name: "Ana"))
        let unsure = CitableSegment(id: 12, channel: .others, start: 192, text: "We keep the budget", speaker: SpeakerTag(id: 4, ordinal: 2, name: "Ana", confidence: 0.2, overlap: true))
        let expected = "[S12 · 03:12 · Others] We keep the budget"
        #expect(VautaPrompts.streamingLine(plain) == expected && VautaPrompts.streamingLine(named) == expected && VautaPrompts.streamingLine(unsure) == expected)
        #expect(VautaPrompts.line(named).contains("Ana (remote)"), "the standard layout still prints names")
        let me = CitableSegment(id: 1, channel: .me, start: 0, text: "Hi", speaker: SpeakerTag(ordinal: 1, name: "Maya", isSelf: true))
        let room = CitableSegment(id: 2, channel: .me, start: 1, text: "Hi", speaker: SpeakerTag(ordinal: 2))
        #expect(VautaPrompts.streamingLine(me).contains("· Me]") && VautaPrompts.streamingLine(room).contains("· Me]"), "the channel only: a renumbering by the final speakers never rewrites a line")
        let renumbered = CitableSegment(id: 12, channel: .others, start: 192, text: "We keep the budget", speaker: SpeakerTag(id: 9, ordinal: 5))
        let none = CitableSegment(id: 12, channel: .others, start: 192, text: "We keep the budget")
        #expect(VautaPrompts.streamingLine(renumbered) == expected && VautaPrompts.streamingLine(none) == expected)
    }

    @Test func whatChangesGoesToTheLastMessageOnly() {
        let segments = [CitableSegment(id: 12, channel: .others, start: 192, text: "We keep the budget", speaker: SpeakerTag(id: 4, ordinal: 2, name: "Ana")),
                        CitableSegment(id: 13, channel: .others, start: 200, text: "Maybe", speaker: SpeakerTag(id: 5, ordinal: 3, confidence: 0.1)),
                        CitableSegment(id: 14, channel: .me, start: 210, text: "Ok", speaker: SpeakerTag(ordinal: 1, name: "Maya", isSelf: true))]
        let frozen = [CandidateEntity(id: 1, kind: .person, name: "Maya", aliases: [])]
        let current = frozen + [CandidateEntity(id: 5, kind: .person, name: "Ana Ruiz", aliases: ["Ana"])]
        let delta = VautaPrompts.contextDelta(segments: segments, frozen: frozen, current: current, selfEntity: 1)
        #expect(delta.contains("[E5] person: Ana Ruiz") && !delta.contains("[E1]"), "only the people added since")
        #expect(delta.contains("Speaker 2 (remote) is Ana") && delta.contains("- Me is Maya (the user)."))
        #expect(delta.contains("S12") || delta.contains("S13"), "who spoke what is in the last message, by segment: \(delta)")
        #expect(delta.contains("S13"), "the speaker the system is unsure about")
        #expect(VautaPrompts.contextDelta(segments: [], frozen: frozen, current: frozen, selfEntity: 1).isEmpty)
        #expect(VautaPrompts.streamingTranscriptMessage(segments).content.hasPrefix("<<<TRANSCRIPT\n") && !VautaPrompts.streamingTranscriptMessage(segments).content.contains("Ana"))
    }

    @Test func speakersAreListedByRunsOfSegments() {
        func seg(_ id: Int64, _ ordinal: Int, _ channel: Channel = .others) -> CitableSegment {
            CitableSegment(id: id, channel: channel, start: TimeInterval(id), text: "x", speaker: SpeakerTag(ordinal: ordinal))
        }
        let segments = [seg(1, 2), seg(2, 2), seg(3, 3), seg(4, 2), seg(5, 2, .me), seg(6, 2, .me)]
        let delta = VautaPrompts.contextDelta(segments: segments, frozen: [], current: [], selfEntity: nil)
        // Speaker 2 has most lines of Others and every line of Others has a speaker: it is "every other line"; the rest are listed.
        #expect(delta.contains("- Every other line of Others: Speaker 2 (remote).") && delta.contains("- Speaker 3 (remote): S3.") && delta.contains("- Me 2 (in the room): S5–6."), "\(delta)")
        // An untagged line on Others: no speaker is left out of the list.
        let untagged = segments + [CitableSegment(id: 7, channel: .others, start: 7, text: "x")]
        let listed = VautaPrompts.contextDelta(segments: untagged, frozen: [], current: [], selfEntity: nil)
        #expect(listed.contains("- Speaker 2 (remote): S1–2, S4.") && !listed.contains("Every other line"), "\(listed)")
        // The same lines read during the meeting and after the final speakers: only the last message differs.
        let before = segments.map { s -> CitableSegment in var o = s; o.speaker = SpeakerTag(ordinal: 7 - s.speaker!.ordinal); return o }
        #expect(VautaPrompts.streamingTranscriptMessage(before) == VautaPrompts.streamingTranscriptMessage(segments))
    }

    @Test func theRulesSitBeforeTheTranscriptAndTheQuestionIsTheLastMessage() {
        let language = OutputLanguage(Locale(identifier: "es-ES"))
        let rules = VautaPrompts.askRulesBody(live: true, laterGuard: true)
        let people = VautaPrompts.streamingPeopleMessage([], selfEntity: nil, rules: rules)
        let question = VautaPrompts.askQuestionMessage("What did Ana say about the budget for the next quarter?", language: language)
        #expect(people.content.hasPrefix("Known people and projects: none.") && people.content.contains("Rules:") && people.content.contains("\"not_yet\""))
        #expect(!rules.contains("Write everything in") && !rules.contains("Spanish"), "the language of the answer is not in the prefix: another language never rereads it")
        #expect(!question.content.contains("Rules:") && question.content.contains("<<<QUESTION") && question.content.contains("Spanish"))
        #expect(PromptText.tokens([question]) <= 160, "the part that changes with each question is small: \(PromptText.tokens([question]))")
        let standard = VautaPrompts.askInstruction("What did Ana say?", language: language, live: true)
        #expect(standard.content.contains("Rules:") && standard.content.contains("<<<QUESTION") && !standard.content.contains("not_yet"))
        for text in [rules, standard.content, VautaPrompts.minutesRules, VautaPrompts.minutesRulesRecall] {
            #expect(text.contains("write quotation marks as « » or ' '") || text.contains("JSON keys stay in English"), "the instruction against inner quotation marks is in every prompt that asks for text")
        }
        #expect(!question.content.contains("write quotation marks") && rules.contains("write quotation marks as « » or ' '"), "stable lines are read once, in the prefix")
    }

    @Test func theKeptPrefixSaysNothingAboutTimeAndEachQuestionBringsItsOwnRule() {
        let language = OutputLanguage(Locale(identifier: "en-US"))
        let prefix = VautaPrompts.askRulesBody(documents: false, timeless: true)
        let live = VautaPrompts.askTimingRules(live: true, laterGuard: false), finished = VautaPrompts.askTimingRules(live: false, laterGuard: false)
        #expect(!prefix.contains("Only what has been said up to now counts") && !prefix.contains("The material is complete") && !prefix.contains("not_yet"))
        #expect(prefix == VautaPrompts.askRulesBody(documents: false, live: true, laterGuard: true, timeless: true), "live or finished, with the guard or not: the same prefix")
        #expect(prefix.contains("\"found\": true if the material answers the question") && !prefix.contains("(or the answer comes later"))
        #expect(live.contains("Only what has been said up to now counts") && finished.contains("The material is complete"))
        let question = VautaPrompts.askQuestionMessage("What did Ana say about the budget for the next quarter?", language: language, timing: live)
        let plain = VautaPrompts.askQuestionMessage("What did Ana say about the budget for the next quarter?", language: language)
        #expect(PromptText.tokens([question]) - PromptText.tokens([plain]) <= 100, "the rule of the moment costs at most 100 tokens: \(PromptText.tokens([question]) - PromptText.tokens([plain]))")
        let guarded = VautaPrompts.askTimingRules(live: true, laterGuard: true)
        #expect(guarded.contains("\"not_yet\"") && PromptText.tokens([.user(guarded)]) <= 200, "\(PromptText.tokens([.user(guarded)]))")
    }

    @Test func theRecallWordingIsOnlyInTheIntegratedMinutes() {
        let base = VautaPrompts.MinutesRequest(meetingDate: .now, language: OutputLanguage(Locale(identifier: "en-US")))
        var recall = base
        recall.recall = true
        let a = VautaPrompts.minutesInstruction(base).content, b = VautaPrompts.minutesInstruction(recall).content
        #expect(!a.contains("every point the group settled") && b.contains("every point the group settled, small or procedural included"))
        #expect(b.contains("a meeting of 30 minutes usually has several of each") && b.contains("the speaker label of who will do it"))
        #expect(a.contains("the speaker label of who will do it") && a.contains("\"Me\" only if the line is labelled Me"), "Apple and the servers get the owner as a speaker label too")
        #expect(!a.contains("if the task is the user's, \"owner\": \"Me\"") && !b.contains("if the task is the user's, \"owner\": \"Me\""))
        #expect(a.contains("do not mention it in the title or the summary unless the transcript does"), "the date is only for resolving relative dates")
    }

    // MARK: One prefix for every task

    @Test func everyTaskOfTheServiceSharesTheSamePrefixThroughTheTranscript() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(id)
        let answer = #"{"found": "yes", "answer": "It stays.", "claims": [{"text": "Kept", "citations": [\#(segments[1].id)], "quote": "we keep the budget as it is"}]}"#
        let chat = WarmChat { messages, options, _ in
            if options.purpose == .ask { return ScriptedChat.reply(messages.last?.content.contains("Do the quoted lines state") == true ? #"{"relation": "states"}"# : answer) }
            if options.purpose == .liveNotes { return ScriptedChat.reply(#"{"points": [], "decisions": [], "tasks": []}"#) }
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: id)
        await service.readMeetingNow(id)
        chat.kept = 100_000   // the model reports the meeting as read
        _ = try await service.ask("What did we decide about the budget?", meetingID: id)
        _ = try await service.liveNotes(meetingID: id, at: 30)
        await service.setRecording(false, meetingID: id)
        await service.regenerateMinutes(id)
        for _ in 0..<12_000 where chat.calls.filter({ $0.options.purpose == .minutes }).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let prefixes = chat.reads.map { Array($0.prefix(3)).map(\.content) } + chat.calls.map { Array($0.messages.prefix(3)).map(\.content) }
        #expect(prefixes.count >= 4 && chat.calls.contains { $0.options.purpose == .minutes } && chat.calls.contains { $0.options.purpose == .liveNotes })
        for (i, p) in prefixes.enumerated().dropFirst() {
            let which = p.indices.filter { p[$0] != prefixes[0][$0] }.map { "message \($0): \(String(p[$0].suffix(120))) vs \(String(prefixes[0][$0].suffix(120)))" }
            #expect(p == prefixes[0], "system, people and TRANSCRIPT are byte-identical in every request (request \(i)) \(chat.calls.map { "\($0.options.purpose) " + $0.messages.map { String($0.content.prefix(25)) }.joined(separator: " | ") }) \(which.count)")
        }
        // The Ask prompt: rules in the prefix, only the question after.
        let ask = try #require(chat.calls.first { $0.options.purpose == .ask })
        #expect(ask.messages.count == 4, "\(ask.messages.map { String($0.content.prefix(30)) })")
        #expect(ask.messages.count == 4 && ask.messages[1].content.contains("Rules:") && ask.messages[3].content.contains("<<<QUESTION") && !ask.messages[3].content.contains("Rules:"))
    }

    @Test func renumberingTheSpeakersAtTheEndDoesNotChangeWhatTheMeetingReadAsItWasRecorded() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        // Three lines of the other participants (the fixture's meeting alternates channels).
        let id = try await f.store.startMeeting(at: .now, locale: Locale(identifier: "en-US"), outputLocale: Locale(identifier: "en-US"))
        for (i, line) in Self.lines.enumerated() {
            try await f.store.append(Segment(channel: .others, start: Double(i * 10), end: Double(i * 10 + 8), text: line, isFinal: true), to: id)
        }
        try await f.store.endMeeting(id, at: Date.now + 600)
        let segments = try await f.store.citableSegments(id)
        let chat = WarmChat { messages, options, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: id)
        // While recording the live clustering numbers the voices 1, 2, 1…
        for (i, s) in segments.enumerated() { await service.segmentSaved(meetingID: id, segmentID: s.id, speaker: 1 + i % 2, characters: 10) }
        await service.readMeetingNow(id)
        chat.kept = 100_000
        let read = try #require(chat.reads.last)
        // The final analysis numbers the same voices the other way round (2, 1, 2…) and names one of them.
        try await f.store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2)],
                                           assignments: segments.enumerated().map { SegmentSpeakerAssignment(segmentID: $1.id, channel: .others, ordinal: 2 - $0 % 2) })
        await service.setRecording(false, meetingID: id)
        await service.regenerateMinutes(id)
        for _ in 0..<12_000 where chat.calls.filter({ $0.options.purpose == .minutes }).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let minutes = try #require(chat.calls.first { $0.options.purpose == .minutes })
        #expect(Array(minutes.messages.prefix(3)).map(\.content) == Array(read.prefix(3)).map(\.content),
                "system, people and TRANSCRIPT are the ones that were read while recording, whatever the final labelling")
        let last = minutes.messages[3].content
        #expect(last.contains("Who spoke") && last.contains("Speaker 1 (remote): S\(segments[1].id)") && last.contains("Every other line of Others: Speaker 2 (remote)"),
                "who spoke each segment (the final numbering) is in the last message: \(last.prefix(900))")
    }

    // MARK: Cold read (see also AskColdReadTests)

    @Test func aSlowColdReadStillSendsTheWholeMeeting() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { messages, _, _ in
            guard let (sid, text) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply(#"{"found": "no", "answer": "Not found.", "claims": []}"#) }
            return ScriptedChat.reply(#"{"found": "yes", "answer": "It stays.", "claims": [{"text": "Kept", "citations": [\#(sid)], "quote": "\#(text.prefix(30))"}]}"#)
        }
        chat.rate = 5   // tokens per second: far too slow to read the meeting while someone waits
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: id)
        let result = try await service.ask("What about the Kobaltix budget?", meetingID: id)
        let asked = try #require(chat.calls.first { $0.options.purpose == .ask })
        #expect(asked.messages.contains { $0.content.hasPrefix("<<<TRANSCRIPT") } && !asked.messages.contains { $0.content.hasPrefix("<<<EXCERPTS FROM YOUR MEETINGS") },
                "the whole transcript, however slow the reading: never an excerpt")
        #expect(asked.options.reusePrefix && asked.options.slot == .meeting, "read into the meeting's kept prefix, so the next question reuses it")
        #expect(result.answer.found)
        // A fast reader (or a warm prefix) reads the whole meeting.
        let fast = WarmChat { messages, _, _ in ScriptedChat.reply(#"{"found": "no", "answer": "Not found.", "claims": []}"#) }
        fast.rate = 100_000
        let service2 = LLMService(store: f.store, providers: TestProviders(chat: fast, contextTokens: 65_536, integrated: true))
        _ = try await service2.ask("What about the Kobaltix budget?", meetingID: id)
        #expect(fast.calls.first?.messages.contains { $0.content.hasPrefix("<<<TRANSCRIPT") } == true && fast.calls.first?.options.reusePrefix == true)
    }

    // MARK: Progress

    @Test func readingProgressIsMonotoneAndHandsOverToWriting() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { messages, options, _ in
            for done in stride(from: 400, through: 4_000, by: 400) { options.onPrefill?(done, 4_000); try await Task.sleep(for: .milliseconds(300)) }
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        let seen = Locked([(LLMService.Stage?, Double?)]())
        await service.setStatusHandler { status in seen.withLock { $0.append((status.stage, status.prefill?.fraction)) } }
        await service.regenerateMinutes(id)
        for _ in 0..<12_000 where !seen.withLock { $0 }.contains(where: { $0.0 == .writingMinutes }) { try await Task.sleep(for: .milliseconds(20)) }
        let snapshot = seen.withLock { $0 }
        let fractions = snapshot.compactMap { $0.0 == .readingTranscript ? $0.1 : nil }
        #expect(fractions.count >= 3, "\(fractions)")
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 }, "monotone: \(fractions)")
        #expect(snapshot.contains { $0.0 == .writingMinutes }, "the stage after reading")
    }
}
