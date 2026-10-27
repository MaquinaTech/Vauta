// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

extension LLMService {
    func beginActivityForTests() { status.activity = "Writing minutes" }
    var stageForTests: Stage? { status.stage }
    var prefillForTests: PrefillProgress? { status.prefill }
}

/// The integrated model reports how far it has read ("Reading the transcript · 42%"); the other providers report nothing.
@Suite("Minutes: reading progress")
struct MinutesProgressTests {
    static func service(integrated: Bool = true) throws -> (LLMService, KnowledgeFixture) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }
        return (LLMService(store: f.store, providers: TestProviders(chat: chat, integrated: integrated)), f)
    }

    @Test func theFractionRisesAndNeverGoesBackWhenAReportArrivesLate() async throws {
        let (service, _) = try Self.service()
        await service.beginActivityForTests()
        await service.progressPrefill(done: 4_200, total: 10_000)
        let stage = await service.stageForTests, fraction = await service.prefillForTests?.fraction
        #expect(stage == .readingTranscript && fraction == 0.42)
        await service.progressPrefill(done: 3_000, total: 10_000)
        #expect(await service.prefillForTests?.done == 4_200, "a late report does not move the bar back")
        await service.progressPrefill(done: 9_000, total: 10_000)
        #expect(await service.prefillForTests?.done == 9_000)
    }

    @Test func reachingTheEndMovesToWritingAndAReportOutsideAJobIsIgnored() async throws {
        let (service, _) = try Self.service()
        await service.progressPrefill(done: 100, total: 1_000)
        #expect(await service.stageForTests == nil, "nothing is running: no stage")
        await service.beginActivityForTests()
        await service.progressPrefill(done: 100, total: 1_000)
        await service.progressPrefill(done: 1_000, total: 1_000)
        let writing = await service.stageForTests, left = await service.prefillForTests
        #expect(writing == .writingMinutes && left == nil)
        await service.clearProgress()
        #expect(await service.stageForTests == nil)
    }

    @Test func aReportThatArrivesAfterTheEndDoesNotBringTheReadingBack() async throws {
        let (service, _) = try Self.service()
        await service.beginActivityForTests()
        // Report 1 is delivered after report 2, the last one: it is older, so the stage stays "writing".
        await service.progressPrefill(done: 100, total: 1_000, reader: 7, sequence: 1)
        await service.progressPrefill(done: 1_000, total: 1_000, reader: 7, sequence: 3)
        await service.progressPrefill(done: 600, total: 1_000, reader: 7, sequence: 2)
        let stage = await service.stageForTests, left = await service.prefillForTests
        #expect(stage == .writingMinutes && left == nil)
    }

    @Test func aQuestionThatCostsAFewTokensShowsNoBar() async throws {
        let (service, _) = try Self.service()
        await service.beginActivityForTests()
        let report = service.prefillReporter(minimumRead: 1_500)
        report(0, 800)   // 800 tokens to read: under the minimum
        report(800, 800)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await service.stageForTests == nil)
        let long = service.prefillReporter(minimumRead: 1_500)
        long(0, 5_000)
        // The report is delivered by a task of its own.
        #expect(await ServiceWarmTests.eventually { await service.stageForTests == .readingTranscript })
    }

    @Test func theMinutesJobGoesFromReadingToWritingAndLeavesNoStageBehind() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is"], locale: "en-US", outputLocale: "en-US")
        let seen = Locked([LLMService.Stage]())
        let chat = WarmChat { messages, options, _ in
            if options.purpose == .minutes {
                // The reports are delivered by tasks of their own: each one is waited for before the next is made.
                options.onPrefill?(100, 400)
                _ = await ServiceWarmTests.eventually { seen.withLock { $0.contains(.readingTranscript) } }
                options.onPrefill?(400, 400)
                _ = await ServiceWarmTests.eventually { seen.withLock { $0.contains(.writingMinutes) } }
            }
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setStatusHandler { status in
            if let stage = status.stage { seen.withLock { if $0.last != stage { $0.append(stage) } } }
        }
        let box = ServiceWarmTests.EventBox()
        await service.setJobEventHandler { box.add($0) }
        await service.regenerateMinutes(id)
        #expect(await ServiceWarmTests.eventually { box.contains(id) })
        #expect(seen.withLock { $0 }.starts(with: [.readingTranscript, .writingMinutes]), "\(seen.withLock { $0 })")
        let endStage = await service.stageForTests, endPrefill = await service.prefillForTests
        #expect(endStage == nil && endPrefill == nil)
    }

    @Test func otherProvidersReportNothing() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is"], locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, options, _ in
            #expect(options.onPrefill == nil, "Apple's model and the servers have no prefill to report")
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536))
        let box = ServiceWarmTests.EventBox()
        await service.setJobEventHandler { box.add($0) }
        await service.regenerateMinutes(id)
        #expect(await ServiceWarmTests.eventually { box.contains(id) })
    }
}
