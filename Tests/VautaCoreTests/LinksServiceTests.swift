// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Links to earlier meetings through the real job queue: the order of the jobs, what waits and what never runs.
@Suite("Links: queue and policy")
struct LinksServiceTests {
    typealias F = LinkFixture
    static let hiring = "Review the hiring plan for the engineering team"

    struct Rig {
        let fixture: KnowledgeFixture
        let service: LLMService
        let embedder: RecordingEmbedder
        let events: EventLog
        let environment: SharedBox<IndexerEnvironment>
        let earlier: Int64
        let later: Int64
        var store: MeetingStore { fixture.store }
    }

    /// An earlier meeting with its minutes and a later one still to be written, both in one series. The model writes the hiring plan task
    /// again in the later meeting.
    static func rig(choice: ModelProviderSettings.Embeddings? = .onDeviceModel, policy: LinkPolicy? = LinkPolicy(), rankedOut: Bool = false,
                    onDevice: Bool = false, checkReply: String? = nil) async throws -> Rig {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let seriesID = try await f.store.saveSeries(MeetingSeries(titlePattern: "Weekly sync"))
        let earlier = try await f.meeting(["We need to review the hiring plan.", "I will review the hiring plan."], locale: "en-US", outputLocale: "en-US",
                                         at: F.base.addingTimeInterval(-7 * F.day))
        let later = try await f.meeting(["Did the hiring plan move on?", "I will review the hiring plan for the engineering team."], locale: "en-US",
                                       outputLocale: "en-US", at: F.base)
        for id in [earlier, later] { try await f.store.setSeries(seriesID, of: id) }
        let segments = try await f.store.segments(of: earlier)
        var minutes = ValidatedMinutes()
        minutes.title = "Weekly sync"
        minutes.summary = "Summary"
        var task = ValidatedMinutes.Task(text: hiring, owner: nil, due: nil, segment: segments[1].id, t: segments[1].start)
        task.unconfirmed = rankedOut
        task.doubt = rankedOut ? "rank" : nil
        minutes.tasks = [task]
        try await f.store.applyMinutes(minutes, to: earlier)
        let chat = ScriptedChat { messages, _, _ in
            if let checkReply, messages.first?.content.contains("You compare tasks and decisions") == true { return ScriptedChat.reply(checkReply) }
            guard let (id, text) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            let quote = String(text.prefix(30)).replacingOccurrences(of: "\"", with: "")
            return ScriptedChat.reply("""
                {"title": "Weekly sync", "summary": "The team met.", "topics": ["hiring"], "decisions": [],
                 "tasks": [{"text": "\(hiring)", "owner": "", "due": "", "seg": \(id), "quote": "\(quote)"}], "entities": [], "open_questions": []}
                """)
        }
        let embedder = RecordingEmbedder()
        let providers = TestProviders(chat: chat, contextTokens: onDevice ? 4_096 : 32_768, embedder: embedder, onDevice: onDevice)
        providers.embeddingChoice = choice
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        let environment = SharedBox(IndexerEnvironment())
        await service.setEnvironmentProvider { environment.value }
        await service.setLinkPolicy(policy)
        return Rig(fixture: f, service: service, embedder: embedder, events: events, environment: environment, earlier: earlier, later: later)
    }

    // MARK: 25 Queue order

    @Test func theJobsRunInTheOrderMinutesEmbedItemsVectorPass() async throws {
        let rig = try await Self.rig()
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { rig.events.events.filter { $0.meetingID == rig.later }.count >= 3 })
        let kinds = rig.events.events.filter { $0.meetingID == rig.later }.map(\.kind)
        #expect(kinds == [.embed, .minutes, .embed], "chunks, minutes, then the items")
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .vector } })
        let traces = await rig.service.linkTraces.filter { $0.meetingID == rig.later }
        #expect(traces.first?.pass == .keyword, "the keyword pass comes right after the minutes: the new items have no vector yet")
        #expect(traces.last?.pass == .vector && (traces.last?.vectors ?? 0) >= 2, "the vector pass reads the vectors of both meetings")
        #expect(try await rig.store.intsForTest("SELECT count(*) FROM item_vectors") == [2])
        let links = try await rig.store.links(ofMeeting: rig.later)
        #expect(links.count == 1 && links[0].state == .suggested && links[0].method == .vector)
        #expect(rig.embedder.texts.value.contains(Self.hiring))
    }

    @Test func onBatteryTheKeywordPassRunsAndTheVectorsWaitForTheCharger() async throws {
        let rig = try await Self.rig()
        rig.environment.mutate { $0.onBattery = true }
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { rig.events.events.contains { $0.meetingID == rig.later && $0.kind == .minutes } })
        #expect(await eventually { try await rig.store.links(ofMeeting: rig.later).count == 1 })
        #expect(try await rig.store.links(ofMeeting: rig.later).first?.method == .keyword)
        #expect(try await rig.store.intsForTest("SELECT count(*) FROM item_vectors") == [0])
        #expect(rig.embedder.documentsEmbedded == 0, "nothing was embedded on battery")
        rig.environment.mutate { $0.onBattery = false }
        await rig.service.environmentChanged()
        #expect(await eventually { try await rig.store.links(ofMeeting: rig.later).first?.method == .vector })
        #expect(try await rig.store.intsForTest("SELECT count(*) FROM item_vectors") == [2])
    }

    @Test func regeneratingTheMinutesQueuesTheItemEmbeddingAgain() async throws {
        let rig = try await Self.rig()
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .vector } })
        let before = rig.embedder.documentsEmbedded
        try await rig.store.executeForTest("DELETE FROM item_vectors")
        await rig.service.regenerateMinutes(rig.later)
        #expect(await eventually { try await rig.store.intsForTest("SELECT count(*) FROM item_vectors") == [2] })
        #expect(rig.embedder.documentsEmbedded >= before + 2)
    }

    // MARK: 34 Policy

    @Test func nothingRunsWhileRecordingOrInTheTwoMinutesAfterAndItWaitsInLowPowerAndHeat() async throws {
        let rig = try await Self.rig(choice: .onDeviceModel)
        let reasons: [(String, @Sendable (inout IndexerEnvironment) -> Void)] = [
            ("recording", { $0.isRecording = true }),
            ("just stopped", { $0.recordingStoppedAt = .now.addingTimeInterval(-30) }),
            ("low power", { $0.lowPowerMode = true }),
            ("heat", { $0.thermalState = .serious }),
        ]
        for (name, apply) in reasons {
            rig.environment.mutate { $0 = IndexerEnvironment(); apply(&$0) }
            let before = await rig.service.linkTraces.count
            await rig.service.itemsChanged(meetingID: rig.later)
            await rig.service.setLinkEditDelayForTest(.milliseconds(5))
            await rig.service.itemsChanged(meetingID: rig.later)
            #expect(await eventually { await rig.service.linksWaiting.contains(rig.later) }, "\(name): the pass waits")
            #expect(await rig.service.linkTraces.count == before, "\(name): no pass")
        }
        #expect(rig.embedder.documentsEmbedded == 0)
        rig.environment.mutate { $0 = IndexerEnvironment() }
        await rig.service.environmentChanged()
        #expect(await rig.service.linksWaiting.isEmpty)
    }

    @Test func aRecordingFlagOnTheServiceStopsThePassToo() async throws {
        let rig = try await Self.rig()
        await rig.service.setRecording(true, meetingID: nil)
        await rig.service.setLinkEditDelayForTest(.milliseconds(5))
        await rig.service.itemsChanged(meetingID: rig.later)
        #expect(await eventually { await rig.service.linksWaiting == [rig.later] })
        #expect(await rig.service.linkTraces.isEmpty && rig.embedder.documentsEmbedded == 0)
    }

    @Test func aModelServersEmbeddingsAreNeverUsedForLinks() async throws {
        let rig = try await Self.rig(choice: nil)   // embeddings on a server
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { rig.events.events.contains { $0.meetingID == rig.later && $0.kind == .minutes } })
        #expect(await eventually { try await rig.store.links(ofMeeting: rig.later).count == 1 })
        #expect(try await rig.store.links(ofMeeting: rig.later).first?.method == .keyword)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await rig.store.intsForTest("SELECT count(*) FROM item_vectors") == [0])
        #expect(!rig.embedder.texts.value.contains(Self.hiring))
    }

    @Test func withLinksOffNothingHappens() async throws {
        let rig = try await Self.rig(policy: nil)
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { rig.events.events.contains { $0.meetingID == rig.later && $0.kind == .minutes } })
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await rig.store.links(ofMeeting: rig.later).isEmpty)
        #expect(await rig.service.linkTraces.isEmpty)
        #expect(try await rig.store.intsForTest("SELECT count(*) FROM item_vectors") == [0])
        #expect(!rig.events.events.contains { $0.meetingID == rig.later && $0.kind == .embed && $0.outcome != .succeeded })
    }

    // MARK: The model check

    @Test func theModelCheckRunsOnTheOnDeviceModelAfterTheVectorsAndCanRemoveASuggestion() async throws {
        var policy = LinkPolicy()
        policy.modelCheck = true
        let rig = try await Self.rig(policy: policy, onDevice: true, checkReply: #"{"pairs":[{"id":"p1","relation":"unrelated","differs":""}]}"#)
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .checked } })
        let checked = try #require(await rig.service.linkTraces.first { $0.pass == .checked })
        #expect(checked.modelCalls == 1)
        #expect(try await rig.store.links(ofMeeting: rig.later).isEmpty, "the model said unrelated")
    }

    @Test func theModelCheckNeverRunsOnAModelServerOrWithTheCheckOff() async throws {
        var policy = LinkPolicy()
        policy.modelCheck = true
        let server = try await Self.rig(policy: policy, onDevice: false, checkReply: #"{"pairs":[{"id":"p1","relation":"unrelated","differs":""}]}"#)
        await server.service.meetingEnded(server.later)
        #expect(await eventually { await server.service.linkTraces.contains { $0.pass == .vector } })
        #expect(await server.service.linkTraces.allSatisfy { $0.modelCalls == 0 })
        #expect(try await server.store.links(ofMeeting: server.later).count == 1)
        let off = try await Self.rig(onDevice: true, checkReply: #"{"pairs":[{"id":"p1","relation":"unrelated","differs":""}]}"#)
        await off.service.meetingEnded(off.later)
        #expect(await eventually { await off.service.linkTraces.contains { $0.pass == .vector } })
        #expect(await off.service.linkTraces.allSatisfy { $0.modelCalls == 0 })
    }

    @Test func aFailingModelCheckLeavesTheDeterministicResult() async throws {
        var policy = LinkPolicy()
        policy.modelCheck = true
        let rig = try await Self.rig(policy: policy, onDevice: true, checkReply: "this is not json")
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .checked } })
        #expect(try await rig.store.links(ofMeeting: rig.later).count == 1)
    }

    // MARK: 37 Ranked-out items are not embedded

    @Test func rankedOutItemsAreNotEmbeddedAndMarkAsCheckedEmbedsThem() async throws {
        let rig = try await Self.rig(rankedOut: true)
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { rig.events.events.filter { $0.meetingID == rig.later }.count >= 3 })
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .vector } })
        #expect(rig.embedder.texts.value.filter { $0 == Self.hiring }.count == 1, "the new item only; the ranked-out earlier one is not embedded")
        #expect(try await rig.store.links(ofMeeting: rig.later).isEmpty, "a ranked-out earlier item is not a candidate")
        // The person checks it: the pass and the embedding run.
        let task = try #require(try await rig.store.tasks(rig.earlier).first)
        try await rig.store.markTaskChecked(task.id)
        await rig.service.setLinkEditDelayForTest(.milliseconds(5))
        await rig.service.itemsChanged(meetingID: rig.later)
        #expect(await eventually { try await rig.store.links(ofMeeting: rig.later).count == 1 })
        #expect(await eventually { try await rig.store.intsForTest("SELECT count(*) FROM item_vectors") == [2] })
    }
}

extension LLMService {
    func setLinkEditDelayForTest(_ delay: Duration) { linkEditDelay = delay }
}
