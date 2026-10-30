// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What the stored rows and the cards say after a cancel, a requeue or the heat latching live answers off.
@Suite("Live answers: stopped, requeued and latched work")
struct QuestionDetectorLifecycleTests {
    typealias Rig = QuestionDetectorTests.Rig

    @Test func questionsWaitingInLineWhenHeatLatchesItOffAreStoredAsStoppedNotAsNoAnswer() async throws {
        let state = Locked(LiveAnswerEnvironment())
        let backend = FakeAnswerBackend()
        backend.answerDelay = .seconds(30)
        var timing = QuestionDetectorTests.fast
        timing.checkInterval = 0.01
        let r = try await QuestionDetectorTests.rig(timing: timing, backend: backend, environment: { state.withLock { $0 } })
        await QuestionDetectorTests.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        await QuestionDetectorTests.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        #expect(await settle { await r.detector.counters.queued == 2 && r.backend.checkTimes.count == 2 })
        state.withLock { $0 = LiveAnswerEnvironment(thermal: .critical) }
        await QuestionDetectorTests.ask(r, "We agreed to move the launch to November.", at: 740, segment: 3)
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.allSatisfy { $0.outcome == .stopped } == true })
        let rows = try await r.store.detectedQuestions(r.meeting)
        #expect(rows.count == 2 && rows.allSatisfy { $0.outcome == .stopped }, "never tried: not \"no answer\"")
        await r.detector.stop()
    }

    @Test func anAnswerWaitingForTheCardBudgetIsNotShownAfterHeatLatchedItOff() async throws {
        var timing = QuestionDetectorTests.fast
        timing.cardInterval = 3_600
        timing.cardWaitMax = 7_200
        let release = Locked(false)
        let state = Locked(LiveAnswerEnvironment())
        let r = try await QuestionDetectorTests.rig(timing: timing, environment: { state.withLock { $0 } }, sleeper: holdingSleeper(release: release))
        await QuestionDetectorTests.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.events.answers.count == 1 })
        await QuestionDetectorTests.ask(r, "When is the deadline for the design review?", at: 730, segment: 2)
        #expect(await settle { r.events.answering.count == 2 && r.backend.answers.count == 2 })
        state.withLock { $0 = LiveAnswerEnvironment(thermal: .critical) }
        await QuestionDetectorTests.ask(r, "We agreed to move the launch to November.", at: 740, segment: 3)
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.count == 2 })
        release.withLock { $0 = true }
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.contains { $0.outcome == .stopped } == true })
        #expect(r.events.answers.count == 1, "the card the sleep was waiting for never appears")
        #expect(await r.detector.counters.shown == 1)
        await r.detector.stop()
    }

    @Test func aRequeuedAnswerNeverTakesTheLineFromANewerQuestion() async throws {
        let backend = FakeAnswerBackend()
        backend.scripted = [.superseded]
        let model = StubGate()
        backend.answerGate = model   // the first answer is being written until the newer question is waiting behind it
        var timing = QuestionDetectorTests.fast
        timing.checkInterval = 0.01
        timing.cardInterval = 0.01
        let r = try await QuestionDetectorTests.rig(timing: timing, backend: backend)
        await QuestionDetectorTests.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        await QuestionDetectorTests.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        #expect(await settle { await r.detector.answerQueue.count == 1 })
        model.open()   // the model gives the first up only now: the newer question is in line
        #expect(await settle { r.events.answers.count == 1 })
        let rows = try await r.store.detectedQuestions(r.meeting)
        let older = try #require(rows.first { $0.text.contains("vendor contract") })
        let newer = try #require(rows.first { $0.text.contains("design review") })
        #expect(older.outcome == .superseded, "closed, not put back over the newer question")
        #expect(newer.outcome == .answered && newer.shown)
        #expect(backend.answers.count == 2)
        await r.detector.stop()
    }

    @Test func theSearchModelDoesNotEmbedACandidateTheCheckBudgetWouldLeaveToGoStale() async throws {
        var timing = QuestionDetectorTests.fast
        timing.checkMax = 1
        timing.checkWindow = 3_600
        // The second check would wait about an hour, far past this; it is not 45 s (the shipped value) because the first question
        // must not go stale while a saturated machine is slow to check it: the detector runs on the real uptime clock.
        timing.staleAfter = 600
        let r = try await QuestionDetectorTests.rig(timing: timing)
        await QuestionDetectorTests.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.backend.checkTimes.count == 1 })
        await QuestionDetectorTests.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        #expect(await settle { r.backend.evidenceCalls == 2 })
        #expect(r.backend.embedFlags == [true, false])
        #expect(await r.detector.counters.embeddingsSkipped == 1)
        await r.detector.stop()
    }

    @Test func aRowStoppedWhileItsAnswerIsBeingWrittenIsStoredAsStoppedAndNeverShown() async throws {
        let backend = FakeAnswerBackend()
        backend.answerDelay = .seconds(30)
        let r = try await QuestionDetectorTests.rig(backend: backend)
        await QuestionDetectorTests.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        let row = try #require(r.events.answering.first).id
        await r.detector.cancel(row: row)
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.first?.outcome == .stopped })
        let stored = try #require(try await r.store.detectedQuestions(r.meeting).first)
        #expect(stored.outcome == .stopped && !stored.shown && stored.answer == nil)
        #expect(await settle { r.events.withdrawn.contains(row) })
        #expect(r.events.answers.isEmpty)
        await r.detector.stop()
    }

    @Test func aRequeuedQuestionEndsAnsweredAndShownNotAsSupersededOrNoAnswer() async throws {
        let backend = FakeAnswerBackend()
        backend.scripted = [.superseded]
        var timing = QuestionDetectorTests.fast
        timing.checkInterval = 0.01
        timing.cardInterval = 0.01
        let r = try await QuestionDetectorTests.rig(timing: timing, backend: backend)
        await QuestionDetectorTests.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.events.answers.count == 1 })
        #expect(backend.answers.count == 2, "asked again once")
        let stored = try #require(try await r.store.detectedQuestions(r.meeting).first)
        #expect(stored.outcome == .answered && stored.shown && stored.answer != nil)
        #expect(try await r.store.detectedQuestions(r.meeting).count == 1, "one row for the question, not one per attempt")
        await r.detector.stop()
    }

    @Test func aQuestionPushedOutAfterTheRequeueWindowIsNotAskedAgain() async throws {
        let backend = FakeAnswerBackend()
        backend.scripted = [.superseded]
        var timing = QuestionDetectorTests.fast
        timing.checkInterval = 0.01
        timing.cardInterval = 0.01
        timing.requeueWithin = 0
        let r = try await QuestionDetectorTests.rig(timing: timing, backend: backend)
        await QuestionDetectorTests.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.first?.outcome == .superseded })
        #expect(backend.answers.count == 1)
        #expect(r.events.answers.isEmpty)
        await r.detector.stop()
    }

    @Test func aCardNeverAppearsAfterCriticalHeatEvenWhenTheAnswerFinishedWithNoWaitingForTheBudget() async throws {
        let state = Locked(LiveAnswerEnvironment())
        let backend = FakeAnswerBackend()
        backend.answerDelay = .milliseconds(400)
        let r = try await QuestionDetectorTests.rig(backend: backend, environment: { state.withLock { $0 } })
        await QuestionDetectorTests.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        state.withLock { $0 = LiveAnswerEnvironment(thermal: .critical) }
        await QuestionDetectorTests.ask(r, "We agreed to move the launch to November.", at: 710, segment: 2)
        // The answer that was being written ends (its row says so) before the absence of a card is asserted.
        #expect(await settle { try await r.store.detectedQuestions(r.meeting).first?.outcome == .stopped })
        try await Task.sleep(for: .milliseconds(450))
        #expect(r.events.answers.isEmpty && backend.answers.count <= 1)
        let stored = try await r.store.detectedQuestions(r.meeting)
        #expect(stored.allSatisfy { !$0.shown })
        await r.detector.stop()
    }
}
