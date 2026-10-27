// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Ask's harness: the question's kind, the numbers of the keyword query, the short windows, the order of the passages and the switch.
@Suite("Ask: harness")
struct AskHarnessTests {
    // MARK: The switch

    @Test func theSwitchParsesAndTheAppShipsNothingYet() {
        #expect(AskHarness.parse("old") == .legacy && AskHarness.parse("new") == .shipped)
        #expect(AskHarness.parse("rule,order") == [.factRule, .order])
        #expect(AskHarness.parse("windows,translate") == [.windows, .queryTranslation])
        #expect(AskHarness.parse("nonsense") == nil)
        #expect(AskHarness.legacy.names == "legacy" && AskHarness.shipped.names == "rule+windows+order+translate")
        #expect(AskHarnessRelease.harness(integrated: false) == .legacy && AskHarnessRelease.harness(integrated: true) == .legacy)
    }

    // MARK: The question's kind

    @Test func aQuestionAboutADecisionIsRecognisedInBothLanguages() {
        for q in ["What did they decide about the budget?", "Was the plan approved?", "Which supplier was chosen?", "Did everyone agree on the date?",
                  "What was the outcome of the vote?", "What was settled about the colours?", "Is there an agreement on the price?",
                  "¿Qué se decidió sobre el presupuesto?", "¿Aprobaron el plan?", "¿Se votó la propuesta?", "¿Qué acordaron sobre la fecha?",
                  "¿Qué proveedor eligieron?", "Did the team go with the plastic case?"] {
            #expect(AskHarness.isDecisionQuestion(q), "\(q)")
        }
    }

    @Test func aQuestionOfFactIsNotADecisionQuestion() {
        for q in ["What is the production cost limit?", "Who will send the numbers?", "How many people attended?", "When is the next meeting?",
                  "¿Cuánto cuesta el prototipo?", "¿Quién envía los números?", "Why did one participant want to use the framework?",
                  "What did Ana say about the colours?", "Who proposed the new schedule?"] {
            #expect(!AskHarness.isDecisionQuestion(q), "\(q)")
        }
    }

    @Test func theRuleAboutProposalsIsSentOnlyWhenAsked() {
        let language = OutputLanguage(Locale(identifier: "en-US"))
        let plain = VautaPrompts.askInstruction("What is the cost limit?", language: language, shortAnswer: true, decisionRule: false).content
        let decision = VautaPrompts.askInstruction("What was decided?", language: language, shortAnswer: true).content
        #expect(!plain.contains("proposed or sent on") && !plain.contains("A proposal") && plain.contains("Answer with the facts the material states"))
        #expect(decision.contains("proposed or sent on") && !decision.contains("Answer with the facts the material states"))
        // The rest of the rules are the same.
        #expect(plain.contains("Reply with one JSON object") && decision.contains("Reply with one JSON object"))
    }

    // MARK: Numbers

    @Test func numbersAreSpelledBothWays() {
        #expect(AskHarness.numberVariants(of: "twelve") == ["12"])
        #expect(AskHarness.numberVariants(of: "doce") == ["12"])
        #expect(Set(AskHarness.numberVariants(of: "12.50")).isSuperset(of: ["twelve", "doce", "50", "fifty", "cincuenta", "half", "medio"]))
        #expect(Set(AskHarness.numberVariants(of: "12,5")).isSuperset(of: ["twelve", "5", "five", "half"]))
        #expect(AskHarness.numberVariants(of: "25").isEmpty, "a number with no single spoken word is left alone")
        #expect(AskHarness.numberVariants(of: "budget").isEmpty && AskHarness.numberVariants(of: "Q3").isEmpty)
        #expect(AskHarness.termGroups(["cost", "12.50"]).first == ["cost"] && AskHarness.termGroups(["cost", "12.50"]).count == 2)
    }

    // MARK: Windows

    static func padded(_ lines: [Int: String], count: Int = 90) -> [String] {
        (0..<count).map { lines[$0] ?? "We went over the agenda item number \($0) and nothing else came of it for now" }
    }

    @Test func aWindowIsShortAndCentredOnTheHit() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.padded([40: "The unit cost limit is twelve fifty euros for the remote", 70: "Louisa will present the casing on Monday"]),
                                     locale: "en-US", outputLocale: "en-US")
        let windows = try await f.store.retrieve("What is the cost limit of 12.50 euros?", queryVector: nil, within: id, limit: 5, maxChars: 4_600,
                                                 locale: Locale(identifier: "en-US"), mode: .keyword, windows: .standard)
        let hit = try #require(windows.first)
        #expect(hit.segments.contains { $0.text.contains("twelve fifty") })
        #expect(hit.segments.count <= 7 && hit.end - hit.start <= 60, "seconds around the hit, not a hundred")
        let chunks = try await f.store.retrieve("What is the cost limit of 12.50 euros?", queryVector: nil, within: id, limit: 3, maxChars: 4_600,
                                                locale: Locale(identifier: "en-US"), mode: .keyword)
        #expect((chunks.first?.segments.count ?? 0) > hit.segments.count, "the chunk of the old retrieval is longer")
    }

    /// The number is the only keyword of the question, and the other lines hold no number, so only the other spelling can find the line.
    @Test func aSpelledNumberFindsADigitLineAndTheOtherWayRound() async throws {
        let f = try KnowledgeFixture()
        func plain(_ lines: [Int: String]) -> [String] { (0..<60).map { lines[$0] ?? "We went over the agenda and nothing else came of it for now" } }
        func found(_ lines: [Int: String], _ question: String, _ tag: String, _ id: String) async throws -> Bool {
            let meeting = try await f.meeting(plain(lines), locale: id, outputLocale: id)
            let windows = try await f.store.retrieve(question, queryVector: nil, within: meeting, limit: 5, maxChars: 4_600,
                                                     locale: Locale(identifier: id), mode: .keyword, windows: .standard)
            return windows.contains { $0.segments.contains { $0.text.contains(tag) } }
        }
        #expect(try await found([30: "Final answer 12 for the remote"], "twelve?", "Final answer 12", "en-US"), "en: spelled finds digits")
        #expect(try await found([30: "Final answer twelve for the remote"], "12?", "Final answer twelve", "en-US"), "en: digits find spelled")
        #expect(try await found([30: "Respuesta final 12 para el mando"], "doce?", "Respuesta final 12", "es-ES"), "es: spelled finds digits")
        #expect(try await found([30: "Respuesta final doce para el mando"], "12?", "Respuesta final doce", "es-ES"), "es: digits find spelled")
    }

    @Test func theWindowsHoldTheBestHitsWithoutOverlapAndWithinTheBudget() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.padded([10: "The prototype cost came to thirteen seventy", 11: "That is one twenty over the limit", 50: "The final cost was twelve thirty euros",
                                                  80: "The cost of the case is fine"]), locale: "en-US", outputLocale: "en-US")
        let found = try await f.store.retrieve("What was the final cost?", queryVector: nil, within: id, limit: 5, maxChars: 4_600,
                                               locale: Locale(identifier: "en-US"), mode: .keyword, windows: .standard)
        #expect(found.count >= 2 && found.count <= 5)
        for (a, b) in zip(found, found.dropFirst()) { #expect(a.end < b.start || b.end < a.start || a.meeting.id != b.meeting.id) }
        #expect(found.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.text.count + 24 } } <= 4_600)
        #expect(found.first?.segments.contains { $0.text.contains("final cost") } == true, "the window that holds more of the question's words ranks first")
    }

    @Test func coverageCountsTheQuestionsIdeasAndTheirNumberSpellings() {
        let profile = LanguageProfile(locale: Locale(identifier: "en-US"))
        let groups = AskHarness.termGroups(["cost", "limit", "12.50"])
        #expect(MeetingStore.coverage(of: groups, in: "the cost limit is twelve fifty", profile: profile) == 1)
        #expect(MeetingStore.coverage(of: groups, in: "the costs were discussed", profile: profile) == 1.0 / 3)
        #expect(MeetingStore.coverage(of: [], in: "anything", profile: profile) == 0)
    }

    // MARK: Order of the passages

    @Test func passagesGoOldestFirstWithTheirPlace() async throws {
        let f = try KnowledgeFixture()
        let newer = try await f.meeting(["The case was changed to plastic"], locale: "en-US", outputLocale: "en-US", at: Date(timeIntervalSince1970: 1_790_700_000))
        let older = try await f.meeting(["The case would be rubber"], locale: "en-US", outputLocale: "en-US", at: Date(timeIntervalSince1970: 1_790_000_000))
        let found = try await f.store.retrieve("case", queryVector: nil, within: nil, limit: 5)
        #expect(Set(found.map(\.meeting.id)) == [newer, older])
        let ordered = VautaPrompts.passagesMessage(found.sorted { $0.meeting.id < $1.meeting.id }, ordered: true).content
        #expect(ordered.contains("Meeting 1 of 2, the oldest") && ordered.contains("Meeting 2 of 2, the most recent") && ordered.contains("(oldest meeting first)"))
        let rubber = try #require(ordered.range(of: "rubber")), plastic = try #require(ordered.range(of: "plastic"))
        #expect(rubber.lowerBound < plastic.lowerBound, "the older meeting is read first")
        let first = try #require(ordered.range(of: "Meeting 1 of 2")), second = try #require(ordered.range(of: "Meeting 2 of 2"))
        #expect(first.lowerBound < rubber.lowerBound && rubber.lowerBound < second.lowerBound)
        // Not switched on: the order and the headings are the old ones.
        let plain = VautaPrompts.passagesMessage(found).content
        #expect(!plain.contains("Meeting 1 of") && !plain.contains("oldest"))
    }

    @Test func aSingleMeetingKeepsItsHeadingAndReadsInTimeOrder() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.padded([5: "The budget was set at ten", 60: "The budget changed to twelve"]), locale: "en-US", outputLocale: "en-US")
        let found = try await f.store.retrieve("budget", queryVector: nil, within: id, limit: 5, mode: .keyword, windows: .standard)
        let text = VautaPrompts.passagesMessage(found.reversed(), ordered: true).content
        #expect(!text.contains("Meeting 1 of") && !text.contains("oldest"))
        let early = try #require(text.range(of: "set at ten")), late = try #require(text.range(of: "changed to twelve"))
        #expect(early.lowerBound < late.lowerBound)
    }

    // MARK: In the service

    static func small(_ f: KnowledgeFixture, harness: AskHarness?) async -> (LLMService, ScriptedChat) {
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ServiceAskTests.answer(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setAskHarness(harness)
        return (service, chat)
    }

    @Test func appleGetsTheFactRuleOnlyWithTheHarnessOnAndOnlyForFacts() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.padded([40: "The unit cost limit is twelve fifty euros for the remote"]), locale: "en-US", outputLocale: "en-US")
        for (harness, question, proposal) in [(AskHarness.shipped, "What is the cost limit for the remote?", false), (.shipped, "What was decided about the cost limit?", true),
                                              (.legacy, "What is the cost limit for the remote?", true), (.factRule, "What is the cost limit for the remote?", false)] {
            let (service, chat) = await Self.small(f, harness: harness)
            _ = try await service.ask(question, meetingID: id)
            let text = try #require(chat.calls.last).text
            #expect(text.contains("proposed or sent on") == proposal, "\(harness.names): \(question)")
        }
    }

    @Test func theWindowsReachAppleAndTheReleaseSwitchKeepsTheOldRetrieval() async throws {
        let f = try KnowledgeFixture()
        // No numbers in the filler: the question's number spellings would otherwise find the numbered agenda lines.
        let id = try await f.meeting((0..<90).map { $0 == 40 ? "The unit cost limit is twelve fifty euros for the remote" : "We went over the agenda and nothing else came of it for now" },
                                     locale: "en-US", outputLocale: "en-US")
        let (service, chat) = await Self.small(f, harness: .shipped)
        let windowed = try await service.ask("What is the cost limit of 12.50 euros?", meetingID: id)
        let (oldService, _) = await Self.small(f, harness: nil)   // the release choice: nothing yet
        let old = try await oldService.ask("What is the cost limit of 12.50 euros?", meetingID: id)
        #expect(windowed.sent.count < old.sent.count, "short windows send fewer lines than the 100 s chunks")
        #expect(windowed.sent.values.contains { $0.text.contains("twelve fifty") })
        #expect(chat.calls.last?.text.contains("twelve fifty") == true)
    }
}
