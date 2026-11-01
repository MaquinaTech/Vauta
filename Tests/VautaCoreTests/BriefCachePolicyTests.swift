// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Brief: cache and invalidation")
struct BriefCacheTests {
    static let occurrence = BriefFixtures.event().occurrence

    static func key(_ change: (inout BriefCacheKey) -> Void = { _ in }) -> BriefCacheKey {
        var k = BriefCacheKey(occurrence: occurrence, storeRevision: 4, documentsGeneration: 2, remindersStamp: 1, searchModelInstalled: true, provider: "apple", language: "en-US")
        change(&k)
        return k
    }

    @Test func aBriefIsReusedOnlyWhenEveryPartOfItsKeyIsTheSame() async {
        let cache = BriefCache()
        let snapshot = AgendaFixtures.snapshot()
        await cache.store(snapshot, key: Self.key())
        #expect(await cache.snapshot(for: Self.key()) == snapshot)
        let changes: [(String, (inout BriefCacheKey) -> Void)] = [
            ("store revision", { $0.storeRevision += 1 }), ("documents", { $0.documentsGeneration += 1 }), ("reminders", { $0.remindersStamp += 1 }),
            ("search model", { $0.searchModelInstalled.toggle() }), ("provider", { $0.provider = "server" }), ("language", { $0.language = "es-ES" }),
        ]
        for (name, change) in changes { #expect(await cache.snapshot(for: Self.key(change)) == nil, "a change of the \(name) makes it stale") }
        let other = BriefFixtures.event("other").occurrence
        #expect(await cache.snapshot(for: BriefCacheKey(occurrence: other)) == nil)
    }

    @Test func aChangeInTheCalendarMakesTheEntryStaleButKeepsItsAgenda() async {
        let cache = BriefCache()
        var snapshot = AgendaFixtures.snapshot()
        snapshot.agenda = .lines([AgendaFixtures.line("Follow up on the revised budget", ["b5"])])
        await cache.store(snapshot, key: Self.key())
        await cache.invalidate(.eventStoreChanged)
        #expect(await cache.snapshot(for: Self.key()) == nil)
        #expect(await cache.previous(for: Self.occurrence)?.agenda == snapshot.agenda)
    }

    @Test func noSuggestionsAndNeedsAModelAreKeptOnlyWhileTheItemsAndTheProviderAreTheSame() {
        for state in [BriefAgendaState.noSuggestions, .unavailable] {
            var old = AgendaFixtures.snapshot()
            old.agenda = state
            let same = BriefCache.carryAgenda(from: old, to: AgendaFixtures.snapshot())
            #expect(same.snapshot.agenda == state && !same.needsAgenda)
            let otherProvider = BriefCache.carryAgenda(from: old, to: AgendaFixtures.snapshot(), sameProvider: false)
            #expect(otherProvider.needsAgenda, "a model that changed is asked")
            var changed = AgendaFixtures.snapshot()
            changed.sections[0].items[0].detail = "a new passage"
            #expect(BriefCache.carryAgenda(from: old, to: changed).needsAgenda, "new items are asked about")
        }
    }

    @Test func lockingTheMeetingsWindowAndErasingDropEverything() async {
        let cache = BriefCache()
        for id in ["a", "b"] { await cache.store(AgendaFixtures.snapshot(), key: BriefCacheKey(occurrence: BriefFixtures.event(id).occurrence)) }
        #expect(await cache.count == 2)
        await cache.invalidate(.locked)
        let afterLock = (await cache.count, await cache.previous(for: BriefFixtures.event("a").occurrence))
        #expect(afterLock.0 == 0 && afterLock.1 == nil, "nothing stays in memory behind the lock")
        await cache.store(AgendaFixtures.snapshot(), key: Self.key())
        await cache.invalidate(.erased)
        #expect(await cache.count == 0)
        await cache.store(AgendaFixtures.snapshot(), key: Self.key())
        await cache.invalidate(.occurrence(Self.occurrence))
        #expect(await cache.count == 0)
    }

    @Test func aFewEntriesAreKeptAndOldOnesDropThirtyMinutesAfterTheEvent() async {
        let cache = BriefCache()
        for i in 0..<(BriefCache.capacity + 3) {
            await cache.store(AgendaFixtures.snapshot(), key: BriefCacheKey(occurrence: BriefFixtures.event("e\(i)").occurrence), now: BriefFixtures.now.addingTimeInterval(Double(i)))
        }
        #expect(await cache.count == BriefCache.capacity)
        let snapshot = AgendaFixtures.snapshot()
        #expect(await cache.nextExpiry() == snapshot.end.addingTimeInterval(BriefCache.retention), "the controller sleeps until this moment, then prunes")
        await cache.prune(now: snapshot.end.addingTimeInterval(BriefCache.retention - 60))
        #expect(await cache.count == BriefCache.capacity)
        await cache.prune(now: snapshot.end.addingTimeInterval(BriefCache.retention + 60))
        #expect(await cache.count == 0)
        #expect(await cache.nextExpiry() == nil)
    }

    @Test func theAgendaIsKeptWhenWhatItCitesIsUnchangedAndWrittenAgainWhenItChanges() {
        var old = AgendaFixtures.snapshot()
        old.agenda = .lines([AgendaFixtures.line("Follow up on the revised budget", ["b5"]), AgendaFixtures.line("Decide on the shell", ["b3"], .decide)])

        // The same items with other IDs (a section above grew): the lines follow their items.
        var moved = AgendaFixtures.snapshot()
        moved.sections[0].items.append(BriefItem(id: "bx", kind: .person, text: "Someone new"))
        var n = 0
        for s in moved.sections.indices { for i in moved.sections[s].items.indices { n += 1; moved.sections[s].items[i].id = "b\(n + 10)" } }
        let carried = BriefCache.carryAgenda(from: old, to: moved)
        #expect(!carried.needsAgenda)
        #expect(carried.snapshot.agenda.lines.map(\.text) == old.agenda.lines.map(\.text))
        #expect(carried.snapshot.agenda.lines.flatMap(\.cites).allSatisfy { carried.snapshot.item($0) != nil }, "every cite exists in the new brief")

        // A cited item changed: the agenda must be written again.
        var changed = AgendaFixtures.snapshot()
        changed.sections[2].items[0] = { var t = changed.sections[2].items[0]; t.due = AgendaFixtures.day(2026, 10, 30); return t }()
        let rewrite = BriefCache.carryAgenda(from: old, to: changed)
        #expect(rewrite.needsAgenda && rewrite.snapshot.agenda == .none)

        // Something the agenda did not cite changed: kept.
        var other = AgendaFixtures.snapshot()
        other.sections[3].items[0].detail = "another passage"
        #expect(!BriefCache.carryAgenda(from: old, to: other).needsAgenda)

        // No earlier agenda: it is asked. "No suggestions" is not asked again for the same inputs.
        #expect(BriefCache.carryAgenda(from: nil, to: other).needsAgenda)
        var failed = AgendaFixtures.snapshot()
        failed.agenda = .noSuggestions
        let same = BriefCache.carryAgenda(from: failed, to: AgendaFixtures.snapshot())
        #expect(!same.needsAgenda && same.snapshot.agenda == .noSuggestions)
    }
}

@Suite("Brief: energy policy and the recording rule")
struct BriefPolicyTests {
    @Test func theRulesOfTheDesign() {
        func policy(_ env: BriefEnvironment, _ backend: BriefBackend? = .apple, loaded: Bool = false) -> BriefPolicy { BriefPolicy.decide(env, backend: backend, integratedLoaded: loaded) }
        #expect(policy(BriefEnvironment()) == BriefPolicy(build: true, pausedForHeat: false, embeddings: true, agenda: .run))
        let recording = policy(BriefEnvironment(isRecording: true))
        #expect(recording.build && !recording.embeddings && recording.agenda == .waitForRecording, "the deterministic brief only, with keywords")
        let lowPower = policy(BriefEnvironment(lowPowerMode: true))
        #expect(!lowPower.embeddings && lowPower.agenda == .skip(.lowPower))
        let serious = policy(BriefEnvironment(thermalState: .serious))
        #expect(serious.build && !serious.embeddings && serious.agenda == .skip(.thermal))
        let critical = policy(BriefEnvironment(thermalState: .critical))
        #expect(!critical.build && critical.pausedForHeat && !critical.embeddings, "\"Brief paused while the Mac cools down\"")
        #expect(policy(BriefEnvironment(onBattery: true)).agenda == .run, "on battery Apple's model runs as usual")
        #expect(policy(BriefEnvironment(onBattery: true), .server).agenda == .run)
        #expect(policy(BriefEnvironment(onBattery: true), .integrated).agenda == .skip(.notLoaded))
        #expect(policy(BriefEnvironment(onBattery: true), .integrated, loaded: true).agenda == .run, "only if it is already loaded")
        #expect(policy(BriefEnvironment(highMemoryPressure: true), .integrated).agenda == .skip(.memoryPressure))
        #expect(policy(BriefEnvironment(), nil).agenda == .skip(.noModel))
        #expect(policy(BriefEnvironment(isRecording: true), nil).agenda == .waitForRecording)
    }

    @Test func theMemoryPressureTheControllerReadsFollowsTheSystemsEvents() {
        let pressure = BriefMemoryPressure()
        pressure.apply(.warning)
        #expect(pressure.isHigh, "a warning sets it")
        pressure.apply(.normal)
        #expect(!pressure.isHigh, "normal clears it")
        pressure.apply(.critical)
        #expect(pressure.isHigh)
        let env = BriefEnvironment(highMemoryPressure: pressure.isHigh)
        #expect(BriefPolicy.decide(env, backend: .integrated, integratedLoaded: false).agenda == .skip(.memoryPressure))
        #expect(BriefPolicy.decide(env, backend: .integrated, integratedLoaded: true).agenda == .run, "a model that is loaded is used")
    }

    @Test func aBriefHasItsOwnGPUPriorityBetweenTheMinutesAndTheLiveNotes() {
        #expect(MLXWorkGate.Priority.minutes < .brief && MLXWorkGate.Priority.brief < .live)
        #expect(ThermalPolicy.action(for: .brief, .serious) == .wait)
        #expect(ThermalPolicy.action(for: .brief, .nominal) == .run)
    }
}

@Suite("Brief: composing a brief")
struct BriefComposerTests {
    static let me = BriefStoreTests.me, ana = BriefStoreTests.ana

    /// A store with two meetings of a series and a retriever that knows other meetings.
    static func rig() async throws -> (KnowledgeFixture, BriefComposer, FakeRetriever, BriefEvent) {
        let f = try KnowledgeFixture()
        let s = f.store!
        let last = try await BriefStoreTests.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-7 * 86_400), attendees: [me, ana])
        try await s.saveCard(MeetingCard(summary: "We compared suppliers.", topics: ["supplier change", "shell material"], openQuestions: ["Who signs off the supplier change?"]), of: last)
        _ = try await s.addDecision(last, text: "Keep the C-shaped shell")
        let anaID = try #require(try await s.entities(.person).first?.id)
        _ = try await s.addTask(last, text: "Send the revised budget", ownerID: anaID, due: BriefFixtures.now)
        _ = try await s.addTask(last, text: "Book the factory visit", ownerID: anaID)
        let retriever = FakeRetriever()
        retriever.meetingHits = [BriefMeetingHit(meetingID: 99, title: "Tooling", date: BriefFixtures.now.addingTimeInterval(-40 * 86_400), text: "shell material tooling", cosine: 0.8)]
        retriever.documentHits = [BriefDocumentHit(sourceID: 4, relPath: "bom.xlsx", fileName: "bom.xlsx", passageKey: "k", text: "supplier change request", cosine: 0.71)]
        let composer = BriefComposer(store: s, retriever: retriever, reminders: FakeReminders(reminders: [
            BriefReminder(id: "r1", title: "Call Ana about the shell material", due: BriefFixtures.now, listID: "L", listName: "Work"),
            BriefReminder(id: "r2", title: "Buy milk", due: nil, listID: "L", listName: "Home")]))
        return (f, composer, retriever, BriefFixtures.event(recurring: true))
    }

    @Test func aBriefIsBuiltFromTheStoreTheRetrievalAndTheReminders() async throws {
        let (f, composer, retriever, event) = try await Self.rig()
        retriever.cosineValues = ["Book the factory visit": 0.9, "Send the revised budget": 0.3, "Call Ana about the shell material": 0.8]
        let revision = await f.store.editRevision
        let result = await composer.build(event, settings: BriefSettings(remindersEnabled: true, reminderListIDs: ["L"]), environment: BriefEnvironment(), showsLastTime: true,
                                          now: BriefFixtures.now)
        let snapshot = try #require(result.snapshot)
        #expect(snapshot.mode == .semantic && result.reminders == .shown)
        #expect(snapshot.sections.map(\.kind) == [.people, .lastTime, .relatedMeetings, .documents, .reminders])
        #expect(snapshot.section(.relatedMeetings)!.items.map(\.meetingID) == [99])
        #expect(snapshot.section(.reminders)!.items.map(\.text) == ["Call Ana about the shell material"])
        #expect(await f.store.editRevision == revision, "building a brief commits nothing")
        // Same inputs, same snapshot.
        let again = await composer.build(event, settings: BriefSettings(remindersEnabled: true, reminderListIDs: ["L"]), environment: BriefEnvironment(), showsLastTime: true,
                                         now: BriefFixtures.now)
        #expect(again.snapshot?.digest == snapshot.digest)
        // As the app builds it (`BriefLastTimeShipping`): no "Last time", the last meeting first among the related ones, Ana's tasks under "Open tasks".
        let shipped = try #require(await composer.build(event, settings: BriefSettings(remindersEnabled: true, reminderListIDs: ["L"]), environment: BriefEnvironment(),
                                                        now: BriefFixtures.now).snapshot)
        #expect(shipped.lastTimeHidden && shipped.sections.map(\.kind) == [.people, .openTasks, .relatedMeetings, .documents, .reminders])
        #expect(shipped.section(.relatedMeetings)!.items.count == 2 && shipped.section(.relatedMeetings)!.items.last?.meetingID == 99)
        #expect(Set(shipped.section(.openTasks)!.items.map(\.text)) == ["Send the revised budget", "Book the factory visit"])
        #expect(!shipped.items.contains { $0.text.contains("Keep the C-shaped shell") || $0.text.contains("We compared suppliers") })
    }

    @Test func whileRecordingNothingIsEmbeddedAndTheRankingIsLexical() async throws {
        let (_, composer, retriever, event) = try await Self.rig()
        let result = await composer.build(event, settings: BriefSettings(), environment: BriefEnvironment(isRecording: true), showsLastTime: true, now: BriefFixtures.now)
        let snapshot = try #require(result.snapshot)
        #expect(snapshot.mode == .keyword && result.policy.agenda == .waitForRecording)
        #expect(!retriever.calls.contains("mode") && !retriever.calls.contains("cosines"), "no model is asked while a meeting is recorded: \(retriever.calls)")
        #expect(retriever.requestedModes.allSatisfy { $0 == .keyword })
        #expect(snapshot.section(.lastTime) != nil, "the deterministic part is there")
    }

    @Test func withoutTheSearchModelOrWhenItFailsKeywordsRank() async throws {
        let (_, composer, retriever, event) = try await Self.rig()
        retriever.rankingMode = .keyword
        var result = await composer.build(event, settings: BriefSettings(), environment: BriefEnvironment(), now: BriefFixtures.now)
        #expect(result.snapshot?.mode == .keyword && !retriever.calls.contains("cosines"))
        retriever.rankingMode = .semantic
        retriever.cosinesAvailable = false
        result = await composer.build(event, settings: BriefSettings(), environment: BriefEnvironment(), now: BriefFixtures.now)
        #expect(result.snapshot?.mode == .keyword, "an embedding that fails falls back to the keyword gate")
        #expect(retriever.requestedModes.suffix(2).allSatisfy { $0 == .keyword })
    }

    @Test func aMacThatIsCriticallyHotBuildsNothing() async throws {
        let (f, composer, retriever, event) = try await Self.rig()
        let revision = await f.store.editRevision
        let result = await composer.build(event, settings: BriefSettings(), environment: BriefEnvironment(thermalState: .critical), now: BriefFixtures.now)
        let after = await f.store.editRevision
        #expect(result.snapshot == nil && result.policy.pausedForHeat && retriever.calls.isEmpty && after == revision)
    }

    @Test func remindersAreReadOnlyWhenAllowedAndTheStateSaysWhy() async throws {
        let (f, _, retriever, event) = try await Self.rig()
        let reminders = [BriefReminder(id: "r1", title: "Call Ana about the shell material", due: nil, listID: "L", listName: "Work")]
        func state(access: BriefReminderAccess, enabled: Bool = true, lists: Set<String> = ["L"]) async -> (BriefRemindersState, Bool) {
            let composer = BriefComposer(store: f.store, retriever: retriever, reminders: FakeReminders(accessValue: access, reminders: reminders))
            let r = await composer.build(event, settings: BriefSettings(remindersEnabled: enabled, reminderListIDs: lists), environment: BriefEnvironment(), now: BriefFixtures.now)
            return (r.reminders, r.snapshot?.section(.reminders) != nil)
        }
        #expect(await state(access: .granted, enabled: false) == (.off, false))
        #expect(await state(access: .notDetermined) == (.notAsked, false))
        #expect(await state(access: .denied) == (.denied, false))
        #expect(await state(access: .granted, lists: []) == (.noLists, false))
        #expect(await state(access: .granted) == (.shown, true))
    }

    @Test func theInvitationsNotesAreUsedInMemoryAndNeverStored() async throws {
        let (f, composer, _, _) = try await Self.rig()
        let event = BriefFixtures.event(recurring: true, notes: "Agenda:\n- SECRET-INVITE-NOTE shell review\n- Tooling quote")
        let on = await composer.build(event, settings: BriefSettings(useInvitationNotes: true), environment: BriefEnvironment(), now: BriefFixtures.now)
        #expect(on.snapshot?.section(.invitation)?.items.map(\.text) == ["SECRET-INVITE-NOTE shell review", "Tooling quote"])
        let off = await composer.build(event, settings: BriefSettings(useInvitationNotes: false), environment: BriefEnvironment(), now: BriefFixtures.now)
        #expect(off.snapshot?.section(.invitation) == nil)
        // Recording the meeting stores the calendar's title, attendees and series, not the description.
        let meeting = try await f.store.startMeeting(at: BriefFixtures.now)
        try await f.store.append(Segment(channel: .me, start: 0, end: 1, text: "hola", isFinal: true), to: meeting)
        _ = try await f.store.applyCalendar(event.calendarMeeting, to: meeting)
        try await f.store.endMeeting(meeting, at: BriefFixtures.now.addingTimeInterval(60))
        let stored = try await f.store.imageContains("SECRET-INVITE-NOTE")
        #expect(!stored)
    }
}

@Suite("Brief: locked Meetings")
struct BriefLockedTests {
    @Test func theLockedCardHoldsTheTitleAndTheTimeAndNothingElse() {
        let event = BriefFixtures.event(notes: "- SECRET-INVITE-NOTE")
        let locked = BriefLockedSummary(event)
        #expect(locked.title == event.title && locked.start == event.start)
        let fields = Mirror(reflecting: locked).children.compactMap(\.label)
        #expect(Set(fields) == ["title", "start", "end", "service"], "no attendee, no item, no note")
        #expect(!"\(locked)".contains("SECRET-INVITE-NOTE") && !"\(locked)".contains("Ana"))
    }
}
