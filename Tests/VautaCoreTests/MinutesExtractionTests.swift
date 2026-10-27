// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The switches of the extraction of decisions, tasks and owners (old against new), the prompts' wording and its budget, the due day that
/// the words must back, and the replay of recorded replies with no model.
@Suite("Minutes: extraction switches, prompts, due days and replay")
struct MinutesExtractionTests {
    @Test func theSwitchesParseAndName() {
        #expect(MinutesExtraction.parse("old") == .legacy && MinutesExtraction.parse("new") == .ranked && MinutesExtraction.parse("integrated") == .shipped)
        #expect(MinutesExtraction.parse("prompts,owners") == [.prompts, .owners])
        #expect(MinutesExtraction.parse("new,explain") == MinutesExtraction.ranked.union(.explain))
        #expect(MinutesExtraction.parse("nonsense") == nil)
        #expect(MinutesExtraction.legacy.names == "legacy" && MinutesExtraction.shipped.names == "prompts+evidence+owners+closing+due" && MinutesExtraction.ranked.names == "prompts+evidence+owners+closing+due+ranking+shape")
        #expect(MinutesArms.shipped.contains(.closingPass) && MinutesArms.parse("closing") == .closingPass && MinutesArms.baseline.names == "baseline")
        #expect(MinutesArms.all.contains(.closingPass), "all lists every arm")
        #expect(MinutesArms.shipped.names(extraction: .legacy) == "streaming" && MinutesArms.shipped.names(extraction: .shipped) == "streaming+closing", "traces name the arms that run")
    }

    // MARK: Prompts

    static let english = OutputLanguage(Locale(identifier: "en-US"))

    @Test func theBlockInstructionCostsAtMostOneHundredFiftyTokensMore() {
        let before = PromptText.tokens([VautaPrompts.blockInstruction(Self.english)])
        let after = PromptText.tokens([VautaPrompts.blockInstruction(Self.english, wording: .init(definitions: true, hasMeLines: false, blockDefinitions: true))])
        #expect(after - before <= 150, "the definitions cost \(after - before) tokens on a 4,096-token window")
        #expect(after > before)
        let text = VautaPrompts.blockInstruction(Self.english, wording: .init(definitions: true, blockDefinitions: true)).content
        #expect(text.contains("At most 3 decisions and 3 tasks") && text.contains("not a question, an opinion, a proposal nobody took up") && text.contains("not something already done"))
    }

    @Test func theOneCallInstructionStaysWithinItsTokenBudget() {
        // Apple's one-call path carries the definitions and owner rules: a meeting near the 4,096-token limit moves to blocks if this grows.
        var request = VautaPrompts.MinutesRequest(meetingDate: .now, language: Self.english)
        let before = PromptText.tokens([VautaPrompts.minutesInstruction(request)])
        request.wording = .init(definitions: true, hasMeLines: true)
        let after = PromptText.tokens([VautaPrompts.minutesInstruction(request)])
        #expect(after - before <= 260, "the definitions and owner rules cost \(after - before) tokens on a 4,096-token window")
        #expect(after <= 1_000, "\(after) tokens")
    }

    @Test func theAppRunsTheReleasedExtractionAndTheEvaluationCanCompareBoth() {
        // Since 2026-10-20: the new extraction on the integrated model; the harness phase adds the ranking for Apple's model.
        #expect(MinutesRelease.extraction(integrated: true) == .shipped)
        #expect(MinutesRelease.extraction(integrated: false) == .ranked)
        #expect(MinutesExtraction.shipped != .legacy && !MinutesRelease.extraction(integrated: true).contains(.explain))
    }

    @Test func theClosingInstructionFitsItsBudget() {
        let request = VautaPrompts.MinutesRequest(meetingDate: .now, language: Self.english)
        let tokens = PromptText.tokens([VautaPrompts.closingInstruction(request)])
        #expect(tokens <= 380, "\(tokens) tokens")
        #expect(VautaPrompts.closingInstruction(request).content.contains("what people agreed to do next"))
    }

    @Test func meIsOnlyOfferedWhenTheTranscriptHasMeLines() {
        let withMe = VautaPrompts.ownerAndDue(.init(definitions: true, hasMeLines: true))
        let without = VautaPrompts.ownerAndDue(.init(definitions: true, hasMeLines: false))
        #expect(withMe.contains("\"Me\" only for a line labelled Me"))
        #expect(!without.contains("Me"), "no Me when no line is the user's: \(without)")
        for text in [withMe, without] { #expect(text.contains("not the asker") && text.contains("only if the words say when")) }
        // The legacy wording is untouched.
        #expect(VautaPrompts.minutesFields.contains("\"Me\" only if the line is labelled Me"))
    }

    @Test func theIntegratedModelIsAskedForANameOnlyWhenTheWordsSayIt() {
        let text = VautaPrompts.ownerAndDue(.init(definitions: true, hasMeLines: true, integrated: true))
        #expect(text.contains("only when the words say who will do it") && !text.contains("\"Speaker 2\"") && !text.contains("not the asker"))
    }

    @Test func theWordingFollowsTheRequest() {
        var request = VautaPrompts.MinutesRequest(meetingDate: .now, language: Self.english)
        #expect(VautaPrompts.minutesInstruction(request).content.contains("\"Me\" only if the line is labelled Me"), "legacy by default")
        request.wording = .init(definitions: true, hasMeLines: false)
        let content = VautaPrompts.minutesInstruction(request).content
        #expect(content.contains("Not a decision") && !content.contains("labelled Me"))
        #expect(VautaPrompts.itemsInstruction(request, first: 1, last: 5, listed: []).content.contains("Not a task"))
        #expect(VautaPrompts.itemsInstruction(request, first: 1, last: 5, listed: [], closing: true).content.contains("The meeting ends with segments S1 to S5"))
        // The summary, topics and digest prompts are the ones they were.
        #expect(VautaPrompts.digestInstruction(request).content == VautaPrompts.digestInstruction(.init(meetingDate: request.meetingDate, language: Self.english)).content)
    }

    // MARK: Due days

    static func zone() -> TimeZone { TimeZone(identifier: "UTC")! }
    static let monday = Date(timeIntervalSince1970: 1_791_763_200)   // 2026-10-12, a Monday

    static func due(_ spoken: [String], model: String?, extraction: MinutesExtraction) throws -> ValidatedMinutes.Task? {
        let segs = Dictionary(uniqueKeysWithValues: spoken.enumerated().map { i, text in
            (Int64(i + 1), CitableSegment(id: Int64(i + 1), channel: .others, start: Double(i) * 10, text: text, speaker: nil))
        })
        let dueJSON = model.map { "\"\($0)\"" } ?? "null"
        let json = #"{"decisions": [], "tasks": [{"text": "Send the revised budget", "owner": null, "owner_id": null, "due": \#(dueJSON), "seg": 1, "quote": "\#(spoken[0].prefix(30))"}]}"#
        return try VautaPrompts.validateMinutes(json, segments: segs, candidates: [], selfEntity: nil, reference: monday, timeZone: zone(), language: "en",
                                                extraction: extraction).tasks.first
    }

    @Test func aDayTheWordsBackIsKeptAndAnUnbackedOneIsDroppedWithTheTaskKept() throws {
        let said = ["We will send the revised budget by Friday.", "Okay."]
        #expect(try Self.due(said, model: "2026-10-16", extraction: .dueEvidence)?.dueDay?.string == "2026-10-16")
        let unbacked = ["We will send the revised budget soon.", "Okay."]
        let dropped = try #require(try Self.due(unbacked, model: "2026-10-16", extraction: .dueEvidence))
        #expect(dropped.dueDay == nil && dropped.due == nil, "the model worked the day out itself")
        // Before this phase the day was kept and marked.
        let legacy = try #require(try Self.due(unbacked, model: "2026-10-16", extraction: .legacy))
        #expect(legacy.dueDay != nil && legacy.unconfirmed)
    }

    @Test func theNextMeetingGivesNoDayAndTheWindowIsReadToo() throws {
        let nextMeeting = try #require(try Self.due(["We will send the revised budget for the next meeting.", "Okay."], model: "2026-10-19", extraction: .dueEvidence))
        #expect(nextMeeting.dueDay == nil)
        let later = try #require(try Self.due(["We will send the revised budget.", "By Friday please."], model: "2026-10-16", extraction: .dueEvidence))
        #expect(later.dueDay?.string == "2026-10-16", "said in the next line")
        #expect(!later.unconfirmed, "a day backed by the next lines is trusted: the task is not to be confirmed for it")
        let none = try #require(try Self.due(["We will send the revised budget."], model: nil, extraction: .dueEvidence))
        #expect(none.dueDay == nil)
    }

    // MARK: Replay

    @Test func recordedRepliesAreSortedByWhatTheyAre() throws {
        let object: [String: Any] = [
            "contextTokens": 4096,
            "diagnostics": ["blocks": 2],
            "calls": [["finishReason": "length"], ["finishReason": "stop"], ["finishReason": "stop"], ["finishReason": "stop"], ["finishReason": "stop"]],
            "replies": [#"{"summary": "cut"#, #"{"summary": "a", "decisions": [], "tasks": []}"#, #"{"summary": "b", "decisions": [], "tasks": []}"#,
                        #"{"title": "T", "summary": "S", "topics": [], "open_questions": []}"#, #"{"decisions": [], "tasks": [{"text": "x"}]}"#],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let replies = try #require(ReplayedReplies(resultFile: data))
        #expect(replies.blocks.count == 3 && replies.blocks[0].truncated && !replies.blocks[1].truncated)
        #expect(replies.final.contains("\"title\"") && replies.closing?.contains("\"tasks\"") == true && replies.contextTokens == 4096)
        #expect(ReplayedReplies(resultFile: Data("{}".utf8)) == nil)
    }

    @Test func aReplayGivesTheSameSummaryAndTopicsWhicheverExtraction() async throws {
        let transcript = try JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: Data(BriefEvaluationTests.transcript([
            "Okay, first the supplier change and the shell material.", "Ana, can you send the revised budget before Friday?", "Yes, I will send it by Friday.",
            "Luis, please book the factory visit.", "Sure, I will book it.", "Good. Let's meet again next week.", "Perfect, see you then.",
            "That is all for today.", "Thank you everybody.", "Bye."]).utf8))
        let reply = #"""
            {"title": "Supplier change", "summary": "The team discussed the supplier change.", "topics": ["supplier", "shell"],
             "decisions": [{"text": "Keep the shell material", "seg": 1, "quote": "the supplier change and the shell material"}],
             "tasks": [{"text": "Send the revised budget", "owner": "Speaker 2", "owner_id": null, "due": "2026-10-16", "seg": 3, "quote": "I will send it by Friday"}],
             "entities": [], "open_questions": ["Who signs?"]}
            """#
        let replies = ReplayedReplies.single(reply, contextTokens: 65_536)
        func run(_ extraction: MinutesExtraction) async throws -> MinutesEvaluation.Result {
            try await MinutesEvaluation.run(transcript, model: .replay(kind: "integrated", replies: replies), arms: [.streamingLayout], extraction: extraction)
        }
        let old = try await run(.legacy), new = try await run(.shipped)
        #expect(old.summary == new.summary && old.topics == new.topics && old.openQuestions == new.openQuestions, "summary, topics and questions are the ones the model wrote")
        #expect(old.summary == "The team discussed the supplier change.")
        #expect(new.items.filter { $0.kind == "task" }.count == 1)
        let task = try #require(new.items.first { $0.kind == "task" })
        #expect(task.citations == [3] && !task.unconfirmed && task.ownerKind == "speaker", "the speaker who committed owns it: \(task)")
        #expect(new.modelCalls <= old.modelCalls + 1)
        #expect(new.diagnostics?.counts["owner.self"] == 1)
    }
}
