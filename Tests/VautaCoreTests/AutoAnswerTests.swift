// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The answer to a question heard in the meeting: `ask` in its auto mode, through the service with a scripted model.
@Suite("Live answers: the answer (S6)")
struct AutoAnswerTests {
    static let lines = ["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is",
                        "Ana will send the numbers on Friday", "The pilot in Berlin starts next month"]

    /// The same meeting with the question said after the line that answers it (the question's own line is never evidence).
    static let withQuestion = Array(lines[0..<2]) + ["Did we keep the budget?"] + Array(lines[2...])

    static func reply(_ claims: [(text: String, id: Int64, quote: String)], answer: String = "The budget is kept as it is.") -> String {
        let list = claims.map { #"{"text": "\#($0.text)", "citations": [\#($0.id)], "quote": "\#($0.quote)"}"# }.joined(separator: ", ")
        return #"{"found": true, "answer": "\#(answer)", "claims": [\#(list)]}"#
    }

    struct Rig {
        let service: LLMService
        let chat: ScriptedChat
        let fixture: KnowledgeFixture
        let meeting: Int64
        let segments: [CitableSegment]
    }

    static func rig(contextTokens: Int = 65_536, integrated: Bool = false, lines: [String] = Self.lines,
                    handler: @escaping ScriptedChat.Handler) async throws -> Rig {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat(handler)
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: contextTokens, integrated: integrated))
        await service.setLiveCheckSeconds(200)
        await service.setRecording(true, meetingID: id)
        return Rig(service: service, chat: chat, fixture: f, meeting: id, segments: try await f.store.citableSegments(id))
    }

    static func autoCalls(_ chat: ScriptedChat) -> [ScriptedChat.Call] { chat.calls.filter { $0.options.purpose == .liveAnswers } }

    // MARK: What is sent and cited

    @Test func theAnswerSeesTheMeetingOnlyUpToTheQuestionsOwnLine() async throws {
        let box = Locked<[Int64]>([])
        let r = try await Self.rig(lines: Self.withQuestion) { _, _, _ in ScriptedChat.reply(Self.reply([("Budget kept", box.withLock { $0[0] }, "we keep the budget as it is")])) }
        box.withLock { $0 = [r.segments[1].id] }
        let outcome = try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all))
        guard case .answered(let content) = outcome else { Issue.record("not answered: \(outcome)"); return }
        #expect(content.claims.count == 1 && content.labels.map(\.kind) == [.thisMeeting])
        let text = try #require(Self.autoCalls(r.chat).last).text
        #expect(text.contains("we keep the budget as it is"))
        #expect(!text.contains("Ana will send the numbers") && !text.contains("The pilot in Berlin"), "nothing said after the question is sent")
    }

    @Test func aCitationOfALineSaidAfterTheQuestionIsNeverVerified() async throws {
        let later = Locked<Int64>(0)
        let r = try await Self.rig(lines: Self.withQuestion) { _, _, _ in ScriptedChat.reply(Self.reply([("Ana sends numbers", later.withLock { $0 }, "Ana will send the numbers on Friday")])) }
        later.withLock { $0 = r.segments[3].id }
        let outcome = try await r.service.autoAnswer("Who sends the numbers?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all))
        #expect(outcome == .noAnswer, "the quote is in a line the model never saw at that moment")
    }

    @Test func onlyAFullyVerifiedFoundAnswerIsShown() async throws {
        let id = Locked<Int64>(0)
        let replies = Locked<[String]>([])
        let r = try await Self.rig(lines: Self.withQuestion) { _, _, _ in
            let next = replies.withLock { $0.isEmpty ? "{}" : $0.removeFirst() }
            return ScriptedChat.reply(next)
        }
        id.withLock { $0 = r.segments[1].id }
        let good = ("Budget kept", r.segments[1].id, "we keep the budget as it is")
        let bad = ("Invented", r.segments[1].id, "the vendor was fired yesterday")
        let request = AutoAskRequest(segmentID: r.segments[2].id, sources: .all)
        func run(_ reply: String...) async throws -> AutoAnswerOutcome {
            replies.withLock { $0 = reply }
            return try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting, request: request)
        }
        if case .answered = try await run(Self.reply([good])) {} else { Issue.record("a verified answer must be shown") }
        #expect(try await run(Self.reply([good, bad])) == .noAnswer, "partly verified")
        #expect(try await run(Self.reply([bad])) == .noAnswer, "unverified")
        #expect(try await run(#"{"found": false, "answer": "I can’t find that.", "claims": []}"#) == .noAnswer, "a refusal")
        #expect(try await run("not json at all", "still not json") == .noAnswer, "an unreadable reply")
    }

    @Test func atMostTwoClaimsAreKept() async throws {
        let ids = Locked<[Int64]>([])
        let r = try await Self.rig(lines: Self.withQuestion) { _, _, _ in
            let s = ids.withLock { $0 }
            return ScriptedChat.reply(Self.reply([("One", s[0], "We reviewed the Kobaltix budget"), ("Two", s[1], "we keep the budget as it is"), ("Three", s[1], "Fine, we keep the budget")]))
        }
        ids.withLock { $0 = [r.segments[0].id, r.segments[1].id] }
        let outcome = try await r.service.autoAnswer("What happened with the budget?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all))
        guard case .answered(let content) = outcome else { Issue.record("not answered"); return }
        #expect(content.claims.count == 2)
    }

    @Test func anUnverifiedClaimBeyondTheCapMakesTheWholeAnswerNoAnswer() async throws {
        let ids = Locked<[Int64]>([])
        let r = try await Self.rig(lines: Self.withQuestion) { _, _, _ in
            let s = ids.withLock { $0 }
            return ScriptedChat.reply(Self.reply([("One", s[0], "We reviewed the Kobaltix budget"), ("Two", s[1], "we keep the budget as it is"),
                                                  ("Three", s[1], "the contract was signed in Lisbon last spring")]))
        }
        ids.withLock { $0 = [r.segments[0].id, r.segments[1].id] }
        let outcome = try await r.service.autoAnswer("What happened with the budget?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all))
        #expect(outcome == .noAnswer, "cutting the third claim must not turn a partly verified answer into a verified one")
    }

    @Test func whenClaimsAreDroppedTheCardShowsTheKeptClaimsNotTheProse() {
        let claims = (1...3).map { VerifiedAnswer.Claim(id: "c\($0)", text: "Fact \($0)", citations: [1], verified: true) }
        let answer = VerifiedAnswer(answer: "Fact 1. Fact 2. Fact 3.", claims: claims, found: true)
        let trimmed = LLMService.trimmed(answer)
        #expect(trimmed.claims.count == 2 && trimmed.answer == "Fact 1. Fact 2")
    }

    @Test func aClaimDroppedForHavingNoQuoteNeverLeavesItsProseOnTheCard() async throws {
        // Apple's and servers' replies: the prose carries "Ana signed it", the claim that would back it has no quote.
        let ids = Locked<[Int64]>([])
        let r = try await Self.rig(lines: Self.withQuestion) { _, _, _ in
            let s = ids.withLock { $0 }
            return ScriptedChat.reply(Self.reply([("The budget is kept", s[1], "we keep the budget as it is"), ("Ana signed it", s[1], "")],
                                                 answer: "The budget is kept and Ana signed it on Tuesday"))
        }
        ids.withLock { $0 = [r.segments[0].id, r.segments[1].id] }
        let outcome = try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all))
        #expect(outcome == .noAnswer, "a dropped claim means part of the prose was never checked")
    }

    @Test func theCardTextIsAlwaysBuiltFromTheVerifiedClaims() {
        let claims = [VerifiedAnswer.Claim(id: "c0", text: "The budget is kept", citations: [1], verified: true)]
        let answer = VerifiedAnswer(answer: "The budget is kept and Ana signed it on Tuesday", claims: claims, found: true)
        #expect(LLMService.trimmed(answer).answer == "The budget is kept")
    }

    @Test func aQuestionsOwnLineIsNeverEvidenceForItsAnswer() async throws {
        let lines = ["We reviewed the Kobaltix budget for the quarter", "Fine, the budget stays", "Didn't we agree to ship on Friday?"]
        let box = Locked<Int64>(0)
        let r = try await Self.rig(lines: lines) { _, _, _ in ScriptedChat.reply(Self.reply([("The team agreed to ship on Friday", box.withLock { $0 }, "agree to ship on Friday")])) }
        box.withLock { $0 = r.segments[2].id }
        let outcome = try await r.service.autoAnswer("Did we agree to ship on Friday?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all))
        #expect(outcome == .noAnswer, "the only support is the question itself")
    }

    @Test func aSplitQuestionsEarlierSegmentIsNotEvidenceEither() async throws {
        let lines = ["We reviewed the Kobaltix budget for the quarter", "Didn't we agree to ship", "on Friday?"]
        let box = Locked<Int64>(0)
        let r = try await Self.rig(lines: lines) { _, _, _ in ScriptedChat.reply(Self.reply([("The team agreed to ship", box.withLock { $0 }, "agree to ship")])) }
        box.withLock { $0 = r.segments[1].id }
        let request = AutoAskRequest(segmentID: r.segments[2].id, questionSegments: [r.segments[1].id], sources: .all)
        let outcome = try await r.service.autoAnswer("Did we agree to ship on Friday?", meetingID: r.meeting, request: request)
        #expect(outcome == .noAnswer)
    }

    @Test func theQuestionsLineIsReadButNotOfferedAsACitation() async throws {
        let lines = ["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is", "Did we keep the budget?"]
        let r = try await Self.rig(lines: lines) { _, _, _ in ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
        _ = try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all))
        let call = try #require(Self.autoCalls(r.chat).last)
        #expect(call.text.contains("Did we keep the budget?"), "the model reads the question's line")
        #expect(call.text.contains("we keep the budget as it is"))
    }

    @Test func onALongMeetingTheAnswerStillSeesTheQuestionsOwnLineAndTheTwoBeforeIt() async throws {
        let filler = (0..<90).map { "Item \($0) of the long agenda covers procurement, staffing and the quarterly plan in some detail for everyone present" }
        let lines = filler + ["Fine, we keep the budget as it is", "Did we keep it?"]
        let r = try await Self.rig(contextTokens: 4_096, lines: lines) { _, _, _ in ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
        // The evidence check found nothing in this meeting (it leaves out the question's own line and the two before it).
        let request = AutoAskRequest(segmentID: r.segments.last!.id, sources: .thisMeeting)
        _ = try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting, request: request)
        let text = try #require(Self.autoCalls(r.chat).last, "the model was asked: the nearby lines are the evidence").text
        #expect(text.contains("we keep the budget as it is") && text.contains("Did we keep it?"))
    }

    // MARK: Sources and labels

    static func pastRig(answerCites: @escaping @Sendable ([CitableSegment], [CitableSegment]) -> (Int64, String)) async throws -> (Rig, LLMService.AskResult?, AutoAskRequest, Int64) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let pastDate = Date(timeIntervalSince1970: 1_790_000_000)
        let past = try await f.meeting(["The pilot budget was fifty thousand euros", "Maria approved the pilot budget"], locale: "en-US", outputLocale: "en-US", at: pastDate)
        let live = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is", "What was the pilot budget?"],
                                       locale: "en-US", outputLocale: "en-US")
        let liveSegments = try await f.store.citableSegments(live)
        let pastSegments = try await f.store.citableSegments(past)
        let (cite, quote) = answerCites(liveSegments, pastSegments)
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(Self.reply([("Cited", cite, quote)])) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536))
        await service.setRecording(true, meetingID: live)
        let found = try await f.store.retrieve("pilot budget fifty thousand", queryVector: nil, within: nil, excluding: live, limit: 3)
        let request = AutoAskRequest(segmentID: liveSegments[2].id, sources: .all, pastPassages: found)
        return (Rig(service: service, chat: chat, fixture: f, meeting: live, segments: liveSegments), nil, request, past)
    }

    @Test func aPastMeetingsPassagesAreOfferedAndLabelledFromTheCitationAlone() async throws {
        let (r, _, request, past) = try await Self.pastRig { _, pastSegments in (pastSegments[0].id, "The pilot budget was fifty thousand euros") }
        #expect(!request.pastPassages.isEmpty && request.pastPassages.allSatisfy { $0.meeting.id == past }, "retrieve(excluding:) leaves the live meeting out")
        let outcome = try await r.service.autoAnswer("What was the pilot budget?", meetingID: r.meeting, request: request)
        guard case .answered(let content) = outcome else { Issue.record("not answered: \(outcome)"); return }
        #expect(content.labels.map(\.kind) == [.pastMeeting])
        let cite = try #require(content.labels.first)
        #expect(cite.meetingID == past && cite.title != nil && cite.date == 1_790_000_000 && cite.t == 0)
        #expect(Self.autoCalls(r.chat).last?.text.contains("EXCERPTS FROM YOUR MEETINGS") == true)
    }

    @Test func passagesThatWereOfferedButNotCitedNeverLabelTheAnswer() async throws {
        let (r, _, request, _) = try await Self.pastRig { live, _ in (live[1].id, "we keep the budget as it is") }
        let outcome = try await r.service.autoAnswer("What was the pilot budget?", meetingID: r.meeting, request: request)
        guard case .answered(let content) = outcome else { Issue.record("not answered: \(outcome)"); return }
        #expect(content.labels.map(\.kind) == [.thisMeeting], "the past meeting was sent but is not cited")
    }

    @Test func labelsAreOrderedThisMeetingPastMeetingDocument() {
        let content = AutoAnswerContent(answer: "x", claims: [
            .init(text: "a", cites: [.init(kind: .document, fileName: "Budget.xlsx", sourceID: 1, relPath: "Budget.xlsx"),
                                      .init(kind: .pastMeeting, meetingID: 4, t: 10, title: "Weekly sync", date: 1_790_000_000),
                                      .init(kind: .thisMeeting, segmentID: 9, meetingID: 7, t: 30)]),
            .init(text: "b", cites: [.init(kind: .thisMeeting, segmentID: 10, meetingID: 7, t: 40)]),
        ])
        #expect(content.labels.map(\.kind) == [.thisMeeting, .pastMeeting, .document])
        #expect(content.sources.count == 3, "one label for each source")
        #expect(!content.usesOnlyThisMeeting)
    }

    @Test func aDeletedSourceDropsItsCitationsAndTheAnswerSaysSo() {
        let content = AutoAnswerContent(answer: "x", claims: [.init(text: "a", cites: [.init(kind: .pastMeeting, meetingID: 4, t: 10, title: "Weekly sync")]),
                                                              .init(text: "b", cites: [.init(kind: .thisMeeting, segmentID: 1, meetingID: 7, t: 3)])])
        let kept = content.removing { $0.kind == .pastMeeting && $0.meetingID != 7 }; let removed = kept != nil
        #expect(removed && kept?.claims.map(\.text) == ["b"])
        let all = AutoAnswerContent(answer: "x", claims: [content.claims[0]]).removing { $0.kind == .pastMeeting }
        #expect(all?.claims.isEmpty == true && all?.removedSources == true && all?.answer == "")
        #expect(kept?.answer == "b", "the prose is rebuilt from the claims that are left")
        #expect(content.removing { _ in false } == nil)
    }

    // MARK: Per backend

    @Test func theIntegratedModelGetsTheLiveCapsAndItsOwnPriority() async throws {
        let id = Locked<Int64>(0)
        let r = try await Self.rig(integrated: true) { _, _, _ in ScriptedChat.reply(Self.reply([("Budget kept", id.withLock { $0 }, "we keep the budget as it is")])) }
        id.withLock { $0 = r.segments[1].id }
        let found = try await r.fixture.store.retrieve("budget", queryVector: nil, within: r.meeting, limit: 3)
        _ = try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting,
                                           request: AutoAskRequest(segmentID: r.segments[1].id, sources: .all, thisMeetingPassages: found))
        let options = try #require(Self.autoCalls(r.chat).last).options
        #expect(options.priority == .autoAnswer && options.maxTokens == 320 && options.maxSeconds == 15 && options.purpose == .liveAnswers)
        guard case .tagged(let key, let cases)? = options.outputSchema else { Issue.record("no grammar"); return }
        #expect(key == "found" && cases.map(\.value) == ["true", "false"], "no three-way found for an answer to a question heard")
        if case .array(_, let lo, let hi)? = cases[0].rest.first(where: { $0.name == "claims" })?.schema { #expect(lo == 1 && hi == 2) } else { Issue.record("no claims") }
        if case .string(let bytes)? = cases[0].rest.first(where: { $0.name == "answer" })?.schema { #expect(bytes == 400) } else { Issue.record("no answer") }
    }

    @Test func theIntegratedModelNeverReadsAColdMeetingForAnAutoAnswer() async throws {
        let id = Locked<Int64>(0)
        let r = try await Self.rig(integrated: true) { _, _, _ in ScriptedChat.reply(Self.reply([("Budget kept", id.withLock { $0 }, "we keep the budget as it is")])) }
        id.withLock { $0 = r.segments[1].id }
        let found = try await r.fixture.store.retrieve("keep the budget", queryVector: nil, within: r.meeting, limit: 3)
        _ = try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting,
                                           request: AutoAskRequest(segmentID: r.segments[1].id, sources: .all, thisMeetingPassages: found))
        let call = try #require(Self.autoCalls(r.chat).last)
        #expect(!call.options.reusePrefix && call.options.slot == nil, "no kept prefix was read, so none is asked for")
        #expect(call.text.contains("EXCERPTS FROM YOUR MEETINGS"), "passages instead of the whole transcript")
    }

    @Test func aWarmPrefixIsUsedAsItIsAndPastMaterialGoesAfterIt() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let past = try await f.meeting(["The pilot budget was fifty thousand euros"], locale: "en-US", outputLocale: "en-US", at: Date(timeIntervalSince1970: 1_790_000_000))
        let live = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "What was the pilot budget?"], locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(live)
        let pastSegments = try await f.store.citableSegments(past)
        let chat = WarmChat { _, _, _ in ScriptedChat.reply(Self.reply([("Pilot", pastSegments[0].id, "pilot budget was fifty thousand euros")])) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setWarmCadence(.init(startDelay: 0, minInterval: 0, minCharacters: 1, maxInterval: 0, lowPowerInterval: 0))
        await service.setRecording(true, meetingID: live)
        await service.readMeetingNow(live)
        let read = try #require(chat.reads.first)
        let found = try await f.store.retrieve("pilot budget", queryVector: nil, within: nil, excluding: live, limit: 3)
        let outcome = try await service.autoAnswer("What was the pilot budget?", meetingID: live,
                                                   request: AutoAskRequest(segmentID: segments[1].id, sources: .all, pastPassages: found, includeExtras: true))
        guard case .answered(let content) = outcome else { Issue.record("not answered: \(outcome)"); return }
        #expect(content.labels.map(\.kind) == [.pastMeeting])
        let call = try #require(chat.calls.last { $0.options.purpose == .liveAnswers })
        #expect(call.options.slot == .meeting && call.options.reusePrefix)
        #expect(call.messages.prefix(3).map(\.content) == read.map(\.content), "system, people and transcript are the ones the prefix was read with")
        #expect(call.messages[3].content.contains("EXCERPTS FROM YOUR MEETINGS"), "past meetings come after the transcript")
        #expect(call.messages.last?.content.contains("What was the pilot budget?") == true)
    }

    @Test func aSmallContextWindowKeepsEveryPromptWithinItsInputBudgetEvenInDenseScripts() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let dense = String(repeating: "会議の予算は五十万円で承認されました。", count: 60)
        let past = try await f.meeting([dense, dense, dense], locale: "ja-JP", outputLocale: "ja-JP", at: Date(timeIntervalSince1970: 1_790_000_000))
        let live = try await f.meeting([dense, "予算はいくらでしたか？"], locale: "ja-JP", outputLocale: "ja-JP")
        let liveSegments = try await f.store.citableSegments(live)
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096))
        await service.setRecording(true, meetingID: live)
        let found = try await f.store.retrieve("予算 五十万円", queryVector: nil, within: nil, excluding: live, limit: 3, maxChars: 40_000)
        let documents = (1...3).map { i in
            DocumentPassage(id: Int64(i), key: "k\(i)", fileID: 1, sourceID: 1, relPath: "f\(i).md", fileName: "f\(i).md", format: .markdown,
                            locator: .section(path: [], block: i), text: dense)
        }
        _ = try await service.autoAnswer("予算はいくらでしたか？", meetingID: live,
                                         request: AutoAskRequest(segmentID: liveSegments[1].id, sources: .all, pastPassages: found, documentPassages: documents))
        let budget = ContextBudget(contextTokens: 4_096)
        for call in Self.autoCalls(chat) { #expect(PromptText.tokens(call.messages) <= budget.askInput, "\(PromptText.tokens(call.messages)) > \(budget.askInput)") }
        #expect(!Self.autoCalls(chat).isEmpty)
        _ = past
    }

    // MARK: Lane and priorities

    @Test func theLaneOrdersTheQuestionBeforeTheAnswerBeforeTheNotes() {
        #expect(LLMService.Priority.ask < .auto && LLMService.Priority.auto < .live && LLMService.Priority.live < .background)
        #expect(MLXWorkGate.Priority.live < .autoAnswer && MLXWorkGate.Priority.autoAnswer < .interactive)
        #expect(ThermalPolicy.action(for: .autoAnswer, .nominal) == .run && ThermalPolicy.action(for: .autoAnswer, .serious) == .giveUp, "optional work never holds the model while the Mac is hot")
        #expect(ThermalPolicy.action(for: .interactive, .serious) == .run, "a question the person typed is never paused by heat below critical")
    }

    @Test func aQuestionTheUserTypesTakesTheModelFromTheAutoAnswer() async throws {
        let r = try await Self.rig { _, options, _ in
            if options.purpose == .liveAnswers { try await Task.sleep(for: .seconds(30)) }
            return ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#)
        }
        let auto = Task { try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[1].id, sources: .all)) }
        #expect(await settle { !Self.autoCalls(r.chat).isEmpty })
        let manual = Task { try await r.service.ask("What is in the plan?", meetingID: r.meeting) }
        let outcome = try await auto.value
        #expect(outcome == .superseded)
        _ = try await manual.value
        #expect(r.chat.calls.contains { $0.options.purpose == .ask })
    }

    @Test func theCheckRunsBeforeTheLiveNotesWhenBothWait() async throws {
        let gate = Gate()
        let r = try await Self.rig { _, options, _ in
            if options.purpose == .ask { await gate.wait(); return ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
            if options.purpose == .liveAnswers { return ScriptedChat.reply(#"{"kind": "information", "question": "Did we keep the budget?", "answered_aloud": false}"#) }
            return ScriptedChat.reply(#"{"points": [], "decisions": [], "tasks": []}"#)
        }
        let holder = Task { try await r.service.ask("Hold the lane", meetingID: r.meeting) }
        #expect(await settle { r.chat.calls.contains { $0.options.purpose == .ask } })
        let notes = Task { try await r.service.liveNotes(meetingID: r.meeting, at: 30) }
        // Wait for the lane's queue, not for time: the notes first, then the check, so the order of arrival is the reverse of the order of service.
        #expect(await settle { await r.service.waiters.count == 1 })
        let check = Task { await r.service.checkQuestion(QuestionCheckTests.settled("Did we keep the budget?"), meetingID: r.meeting) }
        #expect(await settle { await r.service.waiters.count == 2 })
        await gate.release()
        _ = try await holder.value
        _ = try await notes.value
        let result = await check.value
        guard case .checked(let c) = result else { Issue.record("not checked: \(result)"); return }
        #expect(c.kind == .information)
        let order = r.chat.calls.map(\.options.purpose)
        let checkAt = try #require(order.firstIndex(of: .liveAnswers)), notesAt = try #require(order.firstIndex(of: .liveNotes))
        #expect(checkAt < notesAt, "\(order)")
    }

    // MARK: The model check per backend

    @Test func appleNeverChecksNorAnswersQuestionsHeardInTheMeeting() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let live = ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"kind": "information", "question": "Did we keep the budget?", "answered_aloud": false}"#) }
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") })
        providers.liveModel = live
        let service = LLMService(store: f.store, providers: providers)
        await service.setLiveCheckSeconds(200)
        await service.setRecording(true, meetingID: id)
        #expect(service.liveAnswersBackend() == .apple && !service.liveAnswersOffered(), "decision D16: not offered with Apple")
        #expect(await !service.liveAnswersModelAvailable(), "a model is there, but live answers are not offered with it")
        #expect(await service.checkQuestion(QuestionCheckTests.settled(), meetingID: id) == .unavailable)
        let segments = try await f.store.citableSegments(id)
        await #expect(throws: LLMError.self) {
            _ = try await service.autoAnswer("Did we keep the budget?", meetingID: id, request: AutoAskRequest(segmentID: segments[1].id, sources: .all))
        }
        #expect(live.calls.isEmpty, "Apple's model is never asked anything for live answers")
    }

    @Test func aFallbackToAppleInTheMiddleOfAMeetingStopsTheLiveAnswersAndTheReturnOfTheOtherModelResumesThem() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"kind": "information", "question": "Did we keep the budget?", "answered_aloud": false}"#) }
        let providers = TestProviders(chat: chat, integrated: true)
        let service = LLMService(store: f.store, providers: providers)
        await service.setRecording(true, meetingID: id)
        #expect(service.liveAnswersBackend() == .integrated && service.liveAnswersOffered())
        let segments = try await f.store.citableSegments(id)
        let request = AutoAskRequest(segmentID: segments[1].id, sources: .all)
        providers.integrated = false   // the integrated model is gone and Apple's stands in
        let before = chat.calls.count
        #expect(service.liveAnswersBackend() == .apple && !service.liveAnswersOffered())
        #expect(await !service.liveAnswersModelAvailable())
        #expect(await service.checkQuestion(QuestionCheckTests.settled(), meetingID: id) == .unavailable)
        await #expect(throws: LLMError.self) { _ = try await service.autoAnswer("Did we keep the budget?", meetingID: id, request: request) }
        #expect(chat.calls.count == before, "the model that stands in was asked nothing")
        providers.integrated = true
        let available = await service.liveAnswersModelAvailable()
        #expect(service.liveAnswersOffered() && available)
        await service.setLiveCheckSeconds(200)
        #expect(await service.checkQuestion(QuestionCheckTests.settled(), meetingID: id) == .checked(QuestionCheck(kind: .information, question: "Did we keep the budget?", answeredAloud: false)))
    }

    @Test func theAnswerDecidesOnTheProviderItUsesNotOnAnEarlierRead() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }
        let providers = TestProviders(chat: chat, integrated: true)
        let service = LLMService(store: f.store, providers: providers)
        await service.setRecording(true, meetingID: id)
        let segments = try await f.store.citableSegments(id)
        // `autoAnswer` looked while the integrated model was there; by the time `ask` picks the provider Apple's stands in.
        #expect(service.liveAnswersOffered())
        providers.integrated = false
        await #expect(throws: LLMError.self) {
            _ = try await service.ask("Did we keep the budget?", meetingID: id, auto: AutoAskRequest(segmentID: segments[1].id, sources: .all))
        }
        #expect(chat.calls.isEmpty, "Apple's model never answers a question heard in the meeting")
    }

    @Test func theEvaluationCanTakeTheGateOffForItsOwnService() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let live = ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"kind": "information", "question": "Did we keep the budget?", "answered_aloud": false}"#) }
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") })
        providers.liveModel = live
        let service = LLMService(store: f.store, providers: providers)
        await service.setLiveCheckSeconds(200)
        await service.setRecording(true, meetingID: id)
        #expect(await service.checkQuestion(QuestionCheckTests.settled(), meetingID: id) == .unavailable, "the app: gate on")
        service.disableLiveAnswerGate()
        #expect(service.liveAnswersBackend() == .apple && service.liveAnswersOffered(), "llm-eval --providers apple can still measure Apple")
        #expect(await service.checkQuestion(QuestionCheckTests.settled(), meetingID: id) == .checked(QuestionCheck(kind: .information, question: "Did we keep the budget?", answeredAloud: false)))
    }

    @Test func aServerOffersLiveAnswers() throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let service = LLMService(store: f.store, providers: TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }))
        #expect(service.liveAnswersBackend() == .server && service.liveAnswersOffered())
    }

    @Test func theCheckOnAServerAsksForTheSchemaAndRetriesWithoutItWhenRefused() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { _, options, call in
            if call == 1, options.responseFormat != nil { throw LLMError.http(400, message: "no response_format") }
            return ScriptedChat.reply(#"{"kind": "information", "question": "Did we keep the budget?", "answered_aloud": false}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await service.setLiveCheckSeconds(200)
        await service.setRecording(true, meetingID: id)
        let result = await service.checkQuestion(QuestionCheckTests.settled(), meetingID: id)
        #expect(result == .checked(QuestionCheck(kind: .information, question: "Did we keep the budget?", answeredAloud: false)))
        #expect(chat.calls.count == 2 && chat.calls[0].options.responseFormat != nil && chat.calls[1].options.responseFormat == nil)
    }

    @Test func theCheckOnTheIntegratedModelIsASuffixOnTheKeptPrefix() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, _, _ in ScriptedChat.reply(#"{"kind": "information", "question": "Did we keep the budget?", "answered_aloud": false}"#) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setLiveCheckSeconds(200)
        await service.setWarmCadence(.init(startDelay: 0, minInterval: 0, minCharacters: 1, maxInterval: 0, lowPowerInterval: 0))
        await service.setRecording(true, meetingID: id)
        await service.readMeetingNow(id)
        let read = try #require(chat.reads.first)
        let result = await service.checkQuestion(QuestionCheckTests.settled("Did we keep the budget?", before: ["alpha line"]), meetingID: id)
        guard case .checked = result else { Issue.record("not checked: \(result)"); return }
        let call = try #require(chat.calls.last { $0.options.purpose == .liveAnswers })
        #expect(call.options.slot == .meeting && call.options.reusePrefix && call.options.maxSeconds == LLMService.checkGemmaSeconds && call.options.maxTokens == LLMService.checkGemmaTokens)
        #expect(call.messages.prefix(3).map(\.content) == read.map(\.content), "the prefix is not rewritten")
        #expect(!call.messages.last!.content.contains("alpha line"), "the lines before are already in the prefix")
        #expect(call.options.outputSchema != nil)
    }

    @Test func aCheckThatRunsOutOfTimeIsCountedApartFromOneThatFailed() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return ScriptedChat.reply("{}")
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await service.setLiveCheckSeconds(0.05)
        await service.setRecording(true, meetingID: id)
        #expect(await service.checkQuestion(QuestionCheckTests.settled(), meetingID: id) == .timedOut)
    }

    @Test func aModelThatIgnoresCancellationDoesNotHoldTheLanePastTheTimeout() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { _, _, _ in
            // Not cancellable: the continuation is resumed by a timer, whatever the task does.
            await withUnsafeContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 60) { c.resume() } }
            return ScriptedChat.reply("{}")
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await service.setLiveCheckSeconds(0.05)
        await service.setRecording(true, meetingID: id)
        let started = ContinuousClock.now
        #expect(await service.checkQuestion(QuestionCheckTests.settled(), meetingID: id) == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(40), "the check returned at its timeout, not when the model finished")
    }

    @Test func theIntegratedCheckDoesNotReadAPrefixThatIsFarBehindTheTranscript() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, _, _ in ScriptedChat.reply(#"{"kind": "information", "question": "Did we keep the budget?", "answered_aloud": false}"#) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setLiveCheckSeconds(200)
        await service.setWarmCadence(.init(startDelay: 0, minInterval: 0, minCharacters: 1, maxInterval: 0, lowPowerInterval: 0))
        await service.setRecording(true, meetingID: id)
        await service.readMeetingNow(id)
        // Well over the check's allowance (250 tokens) of new transcript: reading it would take the whole timeout.
        for i in 0..<40 {
            _ = try await f.store.append(Segment(channel: .others, start: 100 + Double(i), end: 101 + Double(i), text: String(repeating: "budget review minutes ", count: 12), isFinal: true), to: id)
        }
        let result = await service.checkQuestion(QuestionCheckTests.settled("Did we keep the budget?", before: ["alpha line"]), meetingID: id)
        guard case .checked = result else { Issue.record("not checked: \(result)"); return }
        let call = try #require(chat.calls.last { $0.options.purpose == .liveAnswers })
        #expect(!call.options.reusePrefix && call.options.slot == nil, "the short standalone prompt, not the kept prefix")
        #expect(call.messages.last!.content.contains("alpha line"), "with the lines around the question in it")
    }

    @Test func theCheckIsSkippedWithoutARecordingOrAModel() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let service = LLMService(store: f.store, providers: TestProviders(chat: nil))
        await service.setRecording(true, meetingID: id)
        #expect(await service.checkQuestion(QuestionCheckTests.settled(), meetingID: id) == .unavailable)
        let quiet = LLMService(store: f.store, providers: TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }))
        #expect(await quiet.checkQuestion(QuestionCheckTests.settled(), meetingID: id) == .failed, "no recording, no check")
    }
}
