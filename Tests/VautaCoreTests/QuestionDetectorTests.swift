// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A backend whose answers the test scripts: what the detector asked, and when.
final class FakeAnswerBackend: LiveAnswerBackend, @unchecked Sendable {
    private let lock = NSLock()
    var available = true
    var integrated = false
    var passes = true
    var check: QuestionCheckResult = .checked(QuestionCheck(kind: .information, question: "What was the budget for the second quarter?", answeredAloud: false))
    var outcome: AutoAnswerOutcome = .answered(FakeAnswerBackend.content)
    var answerDelay: Duration = .zero
    var checkDelay: Duration = .zero
    /// A check or an answer that waits for the test to open the gate (so "still in flight" does not depend on how long a delay lasts).
    var checkGate: StubGate?
    var evidenceGate: StubGate?
    var answerGate: StubGate?
    var queryVector: [Float]?
    /// Outcomes handed out first, one per answer; `outcome` is what is returned after them.
    var scripted: [AutoAnswerOutcome] = []
    private var _checkTimes: [Double] = []
    private var _answers: [(String, AutoAskRequest)] = []
    private var _evidence = 0
    private var _checked: [SettledQuestion] = []
    /// The questions the check was asked, as the detector handed them over.
    var checked: [SettledQuestion] { lock.withLock { _checked } }
    private var _embedFlags: [Bool] = []
    var embedFlags: [Bool] { lock.withLock { _embedFlags } }
    var checkTimes: [Double] { lock.withLock { _checkTimes } }
    var answers: [(String, AutoAskRequest)] { lock.withLock { _answers } }
    var evidenceCalls: Int { lock.withLock { _evidence } }

    static let content = AutoAnswerContent(answer: "The budget was fifty thousand euros.",
                                           claims: [.init(text: "Budget", cites: [.init(kind: .thisMeeting, segmentID: 1, meetingID: 1, t: 12)])])

    func modelAvailable() async -> Bool { available }
    func usesIntegratedModel() async -> Bool { integrated }
    func evidence(text: String, locale: String, meetingID: Int64, segmentID: Int64?, sources: LiveAnswerSources, embed: Bool) async -> QuestionEvidence {
        lock.withLock { _evidence += 1; _embedFlags.append(embed) }
        var e = QuestionEvidence()
        if passes { e.passing = [.thisMeeting]; e.best = .thisMeeting }
        e.queryVector = queryVector
        if let gate = evidenceGate { try? await gate.wait() }
        return e
    }
    func check(_ question: SettledQuestion, meetingID: Int64) async -> QuestionCheckResult {
        lock.withLock { _checkTimes.append(ProcessInfo.processInfo.systemUptime); _checked.append(question) }
        if checkDelay > .zero { try? await Task.sleep(for: checkDelay) }
        if let gate = checkGate { try? await gate.wait() }
        return check
    }
    func answer(_ rewrite: String, meetingID: Int64, request: AutoAskRequest) async throws -> AutoAnswerOutcome {
        lock.withLock { _answers.append((rewrite, request)) }
        if answerDelay > .zero { try await Task.sleep(for: answerDelay) }
        if let gate = answerGate { try await gate.wait() }
        return lock.withLock { scripted.isEmpty ? outcome : scripted.removeFirst() }
    }
}

final class EventLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LiveAnswerEvent] = []
    var events: [LiveAnswerEvent] { lock.withLock { _events } }
    func add(_ e: LiveAnswerEvent) { lock.withLock { _events.append(e) } }
    var answers: [AnswerRow] { events.compactMap { if case .answer(let r) = $0 { r } else { nil } } }
    var answering: [AnsweringRow] { events.compactMap { if case .answering(let r) = $0 { r } else { nil } } }
    var withdrawn: [UUID] { events.compactMap { if case .withdrawn(let id) = $0 { id } else { nil } } }
    var pauses: [LiveAnswerPause?] { events.compactMap { if case .paused(let p) = $0 { p } else { nil } } }
}

@Suite("Live answers: the detector, end to end")
struct QuestionDetectorTests {
    static var fast: QuestionTiming {
        var t = QuestionTiming()
        t.settle = 0.05; t.checkInterval = 0.2; t.cardInterval = 0.4; t.staleAfter = 600; t.lateAfter = 60; t.dropAfter = 120; t.cardWaitMax = 2
        return t
    }

    struct Rig {
        let detector: QuestionDetector
        let backend: FakeAnswerBackend
        let events: EventLogBox
        let store: MeetingStore
        let meeting: Int64
    }

    static func rig(settings: LiveAnswerSettings = LiveAnswerSettings.running, timing: QuestionTiming = Self.fast, backend: FakeAnswerBackend = FakeAnswerBackend(),
                    environment: @escaping @Sendable () -> LiveAnswerEnvironment = { LiveAnswerEnvironment() },
                    sleeper: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) async throws -> Rig {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting((1...12).map { "line \($0)" }, locale: "en-US", outputLocale: "en-US")
        let events = EventLogBox()
        let detector = QuestionDetector(backend: backend, store: f.store, meetingID: id, meetingLocale: "en-US", settings: settings, timing: timing,
                                        sleeper: sleeper, environment: environment, onEvent: { events.add($0) })
        return Rig(detector: detector, backend: backend, events: events, store: f.store, meeting: id)
    }

    /// Waits for the positive signal that the detector has taken in `lines` lines and is idle (nothing waiting to settle, being looked at,
    /// queued or answered), so an assertion that nothing happened is made after the detector has acted on everything it was given.
    static func quiet(_ rig: Rig, lines: Int) async {
        _ = await settle {
            let taken = await rig.detector.counters.lines
            let idle = await rig.detector.isIdle
            return taken >= lines && idle
        }
    }

    /// Waits until the detector is idle (see `quiet`), whatever the number of lines.
    static func idle(_ rig: Rig) async {
        _ = await settle { await rig.detector.isIdle }
    }

    static func ask(_ rig: Rig, _ text: String, at start: Double, segment: Int64 = 1) async {
        await rig.detector.ingest(QuestionLine(segmentID: segment, channel: .others, start: start, end: start + 3, text: text))
    }

    @Test func aHeardQuestionBecomesACardAndIsStoredWithItsAnswer() async throws {
        let r = try await Self.rig()
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        let ok = await settle { !r.events.answers.isEmpty }
        let counters = await r.detector.counters
        #expect(ok, "counters \(counters) events \(r.events.events.count) evidence \(r.backend.evidenceCalls) checks \(r.backend.checkTimes.count)")
        let card = try #require(r.events.answers.first)
        #expect(card.question == "What was the budget we agreed for the second quarter?" && card.content.answer.contains("fifty thousand") && card.t == 700)
        #expect(r.events.answering.count == 1 && r.events.answering.first?.id == card.id)
        let request = try #require(r.backend.answers.first)
        #expect(request.0 == "What was the budget for the second quarter?", "the rewrite is what is answered")
        #expect(request.1.segmentID == 1 && request.1.includeExtras)
        let stored = try #require(try await r.store.detectedQuestions(r.meeting).first)
        #expect(stored.outcome == .answered && stored.shown && stored.answer != nil)
        #expect(stored.text == "What was the budget we agreed for the second quarter?" && stored.rewrite == "What was the budget for the second quarter?")
        await r.detector.stop()
    }

    @Test func aStatementNeverReachesTheModel() async throws {
        let r = try await Self.rig()
        await Self.ask(r, "We agreed to move the launch to November.", at: 10)
        await Self.quiet(r, lines: 1)
        #expect(r.backend.evidenceCalls == 0 && r.backend.checkTimes.isEmpty && r.events.answers.isEmpty)
        await r.detector.stop()
    }

    @Test func noEvidenceMeansNoModelCall() async throws {
        let backend = FakeAnswerBackend()
        backend.passes = false
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { backend.evidenceCalls == 1 })
        await Self.idle(r)
        #expect(backend.checkTimes.isEmpty && r.events.answering.isEmpty)
        #expect(await r.detector.counters.noEvidence == 1)
        await r.detector.stop()
    }

    @Test func aCheckThatFailsOrIsNotAnInformationQuestionShowsNothing() async throws {
        for result: QuestionCheckResult in [.failed, .checked(QuestionCheck(kind: .opinion, question: "", answeredAloud: false)),
                                            .checked(QuestionCheck(kind: .rhetorical, question: "", answeredAloud: false))] {
            let backend = FakeAnswerBackend()
            backend.check = result
            let r = try await Self.rig(backend: backend)
            await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
            #expect(await settle { backend.checkTimes.count == 1 })
            await Self.idle(r)
            #expect(r.events.answering.isEmpty && backend.answers.isEmpty)
            #expect(try await r.store.detectedQuestions(r.meeting).isEmpty, "only what the model judged informative is stored")
            await r.detector.stop()
        }
    }

    @Test func aQuestionAnsweredAloudIsStoredButNotShownUnlessThePersonTurnedTheSuppressionOff() async throws {
        let aloud = QuestionCheck(kind: .information, question: "What was the budget?", answeredAloud: true)
        let hidden = FakeAnswerBackend()
        hidden.check = .checked(aloud)
        let a = try await Self.rig(backend: hidden)
        await Self.ask(a, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { hidden.checkTimes.count == 1 })
        await Self.idle(a)
        #expect(hidden.answers.isEmpty)
        #expect(try await a.store.detectedQuestions(a.meeting).map(\.outcome) == [.noAnswer])
        await a.detector.stop()

        var settings = LiveAnswerSettings.running
        settings.hideWhenAnsweredAloud = false
        let shown = FakeAnswerBackend()
        shown.check = .checked(aloud)
        let b = try await Self.rig(settings: settings, backend: shown)
        await Self.ask(b, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { !b.events.answers.isEmpty })
        await b.detector.stop()
    }

    @Test func withoutTheModelCheckTheCandidateGoesStraightToTheAnswerWithItsOwnWords() async throws {
        var settings = LiveAnswerSettings.running
        settings.modelCheck = false
        let r = try await Self.rig(settings: settings)
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { !r.events.answers.isEmpty })
        #expect(r.backend.checkTimes.isEmpty && r.backend.answers.first?.0 == "What was the budget we agreed for the second quarter?")
        await r.detector.stop()
    }

    @Test func aRefusalLeavesNoCardAndTheRowIsWithdrawn() async throws {
        let backend = FakeAnswerBackend()
        backend.outcome = .noAnswer
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { !r.events.withdrawn.isEmpty })
        #expect(r.events.answers.isEmpty)
        #expect(try await r.store.detectedQuestions(r.meeting).map(\.outcome) == [.noAnswer])
        await r.detector.stop()
    }

    @Test func theSameQuestionTwiceIsAnsweredOnce() async throws {
        let r = try await Self.rig()
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { r.backend.checkTimes.count == 1 })
        await Self.ask(r, "What was the budget agreed for the second quarter?", at: 720, segment: 2)
        #expect(await settle { await r.detector.counters.duplicates == 1 })
        #expect(r.backend.checkTimes.count == 1)
        await r.detector.stop()
    }

    @Test func aQuestionTypedInAskIsNotAnsweredAgain() async throws {
        let r = try await Self.rig()
        await r.detector.manualQuestionAsked("What was the budget agreed for the second quarter?")
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        await Self.idle(r)
        #expect(r.backend.evidenceCalls == 0)
        await r.detector.stop()
    }

    @Test func modelChecksNeverComeCloserThanTheInterval() async throws {
        let r = try await Self.rig()
        let questions = ["Who is responsible for the vendor contract?", "When is the deadline for the design review?", "Which supplier did we choose for the packaging?"]
        // Each question settles (and is queued) before the next is heard: a newer question of the same speaker would replace it.
        for (i, q) in questions.enumerated() {
            await Self.ask(r, q, at: 700 + Double(i) * 10, segment: Int64(i + 1))
            #expect(await settle { await r.detector.counters.queued == i + 1 })
        }
        #expect(await settle { r.backend.checkTimes.count >= 3 })
        let times = r.backend.checkTimes
        for pair in zip(times, times.dropFirst()) { #expect(pair.1 - pair.0 >= 0.19, "\(pair.1 - pair.0)") }
        await r.detector.stop()
    }

    @Test func cardsAreSpacedAndAnAnswerThatWaitsTooLongIsStoredNotShown() async throws {
        var timing = Self.fast
        timing.cardInterval = 3_600   // the second card could only follow an hour after the first
        timing.cardWaitMax = 0.3
        let r = try await Self.rig(timing: timing)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.events.answers.count == 1 })
        await Self.ask(r, "When is the deadline for the design review?", at: 730, segment: 2)
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.contains { $0.outcome == .rateLimited } == true })
        #expect(r.events.answers.count == 1)
        #expect(r.backend.answers.count == 1, "an answer that could not reach the card is not generated")
        #expect(r.events.answering.count == 1, "and its row never showed")
        await r.detector.stop()
    }

    @Test func aLateAnswerSaysWhichQuestionItIsFor() async throws {
        var timing = Self.fast
        timing.lateAfter = 0.1
        let backend = FakeAnswerBackend()
        backend.answerDelay = .milliseconds(300)
        let r = try await Self.rig(timing: timing, backend: backend)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answers.isEmpty })
        #expect(r.events.answers.first?.late == true)
        await r.detector.stop()
    }

    @Test func anAnswerReadyAfterTheDropLimitIsStoredAsStale() async throws {
        var timing = Self.fast
        timing.dropAfter = 0.1
        let backend = FakeAnswerBackend()
        backend.answerDelay = .milliseconds(300)
        let r = try await Self.rig(timing: timing, backend: backend)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.first?.outcome == .stale })
        #expect(r.events.answers.isEmpty)
        await r.detector.stop()
    }

    @Test func aMissingModelPausesWithTheReasonAndResumes() async throws {
        let backend = FakeAnswerBackend()
        backend.available = false
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.events.pauses.contains { $0 == .modelUnavailable } })
        backend.available = true
        await Self.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        #expect(await settle { !r.events.answers.isEmpty })
        #expect(r.events.pauses.last == .some(nil), "the pause ends when the model is back")
        await r.detector.stop()
    }

    @Test func heatAndLagPauseTheStagesAfterTheCues() async throws {
        let state = Locked(LiveAnswerEnvironment(thermal: .serious))
        let r = try await Self.rig(environment: { state.withLock { $0 } })
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.events.pauses.contains { $0 == .tooWarm } })
        #expect(r.backend.evidenceCalls == 0)
        state.withLock { $0 = LiveAnswerEnvironment(transcriptionLagging: true) }
        await Self.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        #expect(await settle { r.events.pauses.contains { $0 == .transcriptBehind } })
        #expect(r.backend.evidenceCalls == 0)
        state.withLock { $0 = LiveAnswerEnvironment() }
        await Self.ask(r, "Which supplier did we choose for the packaging?", at: 740, segment: 3)
        #expect(await settle { !r.events.answers.isEmpty })
        await r.detector.stop()
    }

    @Test func criticalHeatTurnsItOffUntilTheRecordingEnds() async throws {
        let state = Locked(LiveAnswerEnvironment(thermal: .critical))
        let r = try await Self.rig(environment: { state.withLock { $0 } })
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        state.withLock { $0 = LiveAnswerEnvironment() }
        await Self.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        // Once latched off the detector takes in no more lines: only the first was counted.
        await Self.quiet(r, lines: 1)
        #expect(await r.detector.counters.lines == 1)
        #expect(r.backend.evidenceCalls == 0 && r.events.answers.isEmpty, "off for this recording even after it cooled down")
        await r.detector.stop()
    }

    @Test func lowPowerModeChecksFewerSentences() async throws {
        let r = try await Self.rig(environment: { LiveAnswerEnvironment(lowPowerMode: true) })
        // A mark alone (0.50) passes Standard but not Fewer answers.
        await Self.ask(r, "Did the committee approve the revised proposal?", at: 700)
        await Self.quiet(r, lines: 1)
        #expect(r.backend.evidenceCalls == 0)
        await r.detector.stop()
    }

    // MARK: Review fixes

    @Test func aSupersededAnswerIsAskedAgainOnceWhenTheManualQuestionIsAboutSomethingElse() async throws {
        let backend = FakeAnswerBackend()
        backend.scripted = [.superseded]
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { r.events.answers.count == 1 })
        #expect(backend.answers.count == 2, "asked, superseded by the person's own question, asked again")
        #expect(try await r.store.detectedQuestions(r.meeting).first?.outcome == .answered)
        await r.detector.stop()
    }

    @Test func aSupersededAnswerIsNotAskedAgainWhenThePersonAskedTheSameThing() async throws {
        let backend = FakeAnswerBackend()
        backend.scripted = [.superseded]
        let server = StubGate()
        backend.answerGate = server
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        await r.detector.manualQuestionAsked("What was the budget agreed for the second quarter?")
        server.open()   // the model gives the answer up only now, after the person's own question
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.first?.outcome == .superseded })
        await Self.idle(r)
        #expect(backend.answers.count == 1 && r.events.answers.isEmpty)
        await r.detector.stop()
    }

    // MARK: Switch, heat and the card budget during the work

    @Test func turningItOffDuringTheModelCheckStoresNothingAndStartsNoAnswer() async throws {
        let backend = FakeAnswerBackend()
        let model = StubGate()
        backend.checkGate = model
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.backend.checkTimes.count == 1 })
        var off = LiveAnswerSettings.running
        off.enabled = false
        await r.detector.update(settings: off)
        model.open()   // the model reads on while the switch is off
        #expect(await settle { await r.detector.checkWorker == nil })
        #expect(try await r.store.detectedQuestions(r.meeting).isEmpty, "a feature that was turned off stores nothing")
        #expect(r.backend.answers.isEmpty && r.events.answering.isEmpty)
        await r.detector.stop()
    }

    @Test func settingsThatNobodySwitchedOnRunNothing() async throws {
        let r = try await Self.rig(settings: LiveAnswerSettings())   // `enabled` starts off, as a recording on Apple's model gets it
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        await Self.quiet(r, lines: 0)
        #expect(await r.detector.counters.lines == 0)
        #expect(r.backend.checkTimes.isEmpty && r.events.answering.isEmpty && r.events.answers.isEmpty)
        await r.detector.stop()
    }

    @Test func theModelGoingBackToAnOfferingBackendResumesTheDetectionFromThenOn() async throws {
        let r = try await Self.rig(settings: LiveAnswerSettings())
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        await r.detector.update(settings: .running)   // Gemma is back
        await Self.ask(r, "When is the deadline for the design review?", at: 760, segment: 2)
        #expect(await settle { !r.events.answers.isEmpty })
        #expect(await r.detector.counters.lines == 1, "the line heard while it was off is not looked at afterwards")
        await r.detector.stop()
    }

    @Test func criticalHeatDuringTheModelCheckStoresNothingAndStartsNoAnswer() async throws {
        let state = Locked(LiveAnswerEnvironment())
        let backend = FakeAnswerBackend()
        let model = StubGate()
        backend.checkGate = model
        let r = try await Self.rig(backend: backend, environment: { state.withLock { $0 } })
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.backend.checkTimes.count == 1 })
        state.withLock { $0 = LiveAnswerEnvironment(thermal: .critical) }
        await Self.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        model.open()   // the model reads on while the heat is critical
        #expect(await settle { await r.detector.checkWorker == nil })
        #expect(try await r.store.detectedQuestions(r.meeting).isEmpty)
        #expect(r.backend.answers.isEmpty && r.events.answering.isEmpty)
        await r.detector.stop()
    }

    @Test func seriousHeatDuringTheModelCheckPausesBeforeStoringOrAnswering() async throws {
        let state = Locked(LiveAnswerEnvironment())
        let backend = FakeAnswerBackend()
        let model = StubGate()
        backend.checkGate = model
        let r = try await Self.rig(backend: backend, environment: { state.withLock { $0 } })
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.backend.checkTimes.count == 1 })
        state.withLock { $0 = LiveAnswerEnvironment(thermal: .serious) }
        model.open()   // the model reads on while the Mac is hot
        #expect(await settle { await r.detector.checkWorker == nil })
        #expect(try await r.store.detectedQuestions(r.meeting).isEmpty)
        #expect(r.backend.answers.isEmpty && r.events.answering.isEmpty)
        await r.detector.stop()
    }

    @Test func seriousHeatStopsAnAnswerBeingWritten() async throws {
        let state = Locked(LiveAnswerEnvironment())
        let backend = FakeAnswerBackend()
        backend.answerDelay = .seconds(30)
        let r = try await Self.rig(backend: backend, environment: { state.withLock { $0 } })
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        let row = try #require(r.events.answering.first?.id)
        state.withLock { $0 = LiveAnswerEnvironment(thermal: .serious) }
        await Self.ask(r, "We agreed to move the launch to November.", at: 720, segment: 2)
        #expect(await settle { r.events.withdrawn.contains(row) })
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.first?.outcome == .stopped })
        #expect(r.events.answers.isEmpty)
        await r.detector.stop()
    }

    @Test func anAnswerThatWasQueuedWhenHeatArrivesIsNotStarted() async throws {
        let state = Locked(LiveAnswerEnvironment())
        let backend = FakeAnswerBackend()
        backend.answerDelay = .seconds(30)
        var timing = Self.fast
        timing.checkInterval = 0.01
        let r = try await Self.rig(timing: timing, backend: backend, environment: { state.withLock { $0 } })
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        await Self.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        #expect(await settle { await r.detector.counters.queued == 2 && r.backend.checkTimes.count == 2 })
        state.withLock { $0 = LiveAnswerEnvironment(thermal: .serious) }
        await Self.ask(r, "We agreed to move the launch to November.", at: 740, segment: 3)
        #expect(await settle { await r.detector.counters.stopped >= 1 && r.events.withdrawn.count >= 1 })
        await Self.idle(r)
        #expect(r.backend.answers.count == 1, "the queued answer did not start while the Mac was hot")
        await r.detector.stop()
    }

    @Test func stoppingARowDuringTheCardWaitSpendsNoBudgetAndStoresItAsStopped() async throws {
        var timing = Self.fast
        timing.cardInterval = 3_600
        timing.cardWaitMax = 7_200
        let release = Locked(false)
        let r = try await Self.rig(timing: timing, sleeper: holdingSleeper(release: release))
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.events.answers.count == 1 })
        await Self.ask(r, "When is the deadline for the design review?", at: 730, segment: 2)
        #expect(await settle { r.events.answering.count == 2 && r.backend.answers.count == 2 })
        let row = try #require(r.events.answering.last?.id)
        await r.detector.cancel(row: row)
        release.withLock { $0 = true }
        #expect(await settle { r.events.withdrawn.contains(row) })
        let rows = try await r.store.detectedQuestions(r.meeting)
        #expect(rows.count == 2 && rows.filter(\.shown).count == 1 && rows.contains { $0.outcome == .stopped })
        #expect(await r.detector.counters.shown == 1 && r.events.answers.count == 1)
        await r.detector.stop()
    }

    @Test func aCandidateWhoseCheckFailedIsAskedAgainWithoutBeingTakenForADuplicate() async throws {
        let backend = FakeAnswerBackend()
        backend.check = .failed
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { r.backend.checkTimes.count == 1 })
        #expect(await settle { await r.detector.isIdle })
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 720, segment: 2)
        #expect(await settle { r.backend.checkTimes.count == 2 })
        #expect(await r.detector.counters.duplicates == 0)
        await r.detector.stop()
    }

    @Test func twoQuestionsWithTheSameMeaningAreOneWhenTheSearchModelEmbeddedThem() async throws {
        let backend = FakeAnswerBackend()
        backend.queryVector = [0.6, 0.8, 0]
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.backend.checkTimes.count == 1 })
        await Self.ask(r, "Which supplier did we choose for the packaging?", at: 720, segment: 2)
        #expect(await settle { await r.detector.counters.duplicates == 1 })
        #expect(r.backend.checkTimes.count == 1)
        await r.detector.stop()
    }

    @Test func stoppingARowCancelsItsAnswerClosesItAsStoppedAndItNeverComesBack() async throws {
        let backend = FakeAnswerBackend()
        backend.answerDelay = .seconds(30)
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        let row = try #require(r.events.answering.first?.id)
        await r.detector.cancel(row: row)
        #expect(await settle { r.events.withdrawn.contains(row) })
        #expect(try await r.store.detectedQuestions(r.meeting).first?.outcome == .stopped)
        await Self.idle(r)
        #expect(r.events.answers.isEmpty && backend.answers.count == 1, "not asked again, no card")
        // The detector is free for the next question.
        backend.answerDelay = .zero
        await Self.ask(r, "When is the deadline for the design review?", at: 740, segment: 2)
        #expect(await settle { r.events.answers.count == 1 })
        await r.detector.stop()
    }

    @Test func aRowStillWaitingInLineLeavesTheLineWhenItIsStopped() async throws {
        let backend = FakeAnswerBackend()
        backend.answerDelay = .seconds(30)
        var timing = Self.fast
        timing.checkInterval = 0.01
        let r = try await Self.rig(timing: timing, backend: backend)
        await Self.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        await Self.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        #expect(await settle { await r.detector.counters.queued == 2 && r.backend.checkTimes.count == 2 })
        await r.detector.stop()
        #expect(r.events.answers.isEmpty)
    }

    @Test func aMidRecordingSwitchToLowPowerModeLowersTheCuesAtOnce() async throws {
        let state = Locked(LiveAnswerEnvironment())
        let r = try await Self.rig(environment: { state.withLock { $0 } })
        state.withLock { $0 = LiveAnswerEnvironment(lowPowerMode: true) }
        // A mark alone (0.50) passes Standard but not Fewer answers.
        await Self.ask(r, "Did the committee approve the revised proposal?", at: 700)
        await Self.idle(r)
        #expect(r.backend.evidenceCalls == 0)
        await r.detector.stop()
    }

    @Test func thePauseLineLeavesWhenItsCauseClearsNotAtTheNextQuestion() async throws {
        let backend = FakeAnswerBackend()
        backend.available = false
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.events.pauses.contains { $0 == .modelUnavailable } })
        backend.available = true
        await Self.ask(r, "We agreed to move the launch to November.", at: 720, segment: 2)
        #expect(await settle { r.events.pauses.last == .some(nil) })
        await r.detector.stop()
    }

    @Test func stoppingDoesNotWaitForAnAnswerThatIsWaitingForTheCardBudget() async throws {
        var timing = Self.fast
        timing.cardInterval = 3_600
        timing.cardWaitMax = 7_200
        var settings = LiveAnswerSettings.running
        settings.keepDetectedQuestions = true
        // The card budget lasts an hour and the sleeper only ends when cancelled: `stop` returning at all proves it did not wait for it.
        let r = try await Self.rig(settings: settings, timing: timing, sleeper: holdingSleeper())
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { r.events.answers.count == 1 })
        await Self.ask(r, "When is the deadline for the design review?", at: 740, segment: 2)
        #expect(await settle { r.backend.answers.count == 2 })
        await r.detector.stop()
        #expect(r.events.answers.count == 1, "the answer sleeping for its card did not hold the end of the recording, and was never shown")
    }

    @Test func theQueueKeepsItsFirstEntryWhenPeekedAndDropsWhatIsStale() {
        var queue = QuestionQueue<Int>(capacity: 2, staleAfter: 10)
        queue.push(1, at: 0); queue.push(2, at: 8)
        let seen = queue.peek(now: 11)
        #expect(seen.item == 2 && seen.stale == [1] && queue.count == 1, "the stale entry went, the first one stays in line")
        #expect(queue.remove(where: { $0 == 2 }) == [2] && queue.isEmpty)
    }

    @Test func turningItOffCancelsWhatIsInFlightAndHidesTheRows() async throws {
        let backend = FakeAnswerBackend()
        backend.answerDelay = .seconds(5)
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answering.isEmpty })
        var off = LiveAnswerSettings.running
        off.enabled = false
        await r.detector.update(settings: off)
        #expect(await settle { !r.events.withdrawn.isEmpty })
        #expect(r.events.answers.isEmpty)
        #expect(await settle { (try? await r.store.detectedQuestions(r.meeting))?.first?.outcome == .stopped }, "closed as stopped, not as a newer question's supersede")
        await Self.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        await Self.idle(r)
        #expect(r.backend.evidenceCalls == 1, "nothing new is looked at while it is off")
    }

    @Test func stoppingTheRecordingDropsWhatIsQueuedAndKeepsNothingUnkeptWhenTheSettingIsOff() async throws {
        var settings = LiveAnswerSettings.running
        settings.keepDetectedQuestions = false
        let r = try await Self.rig(settings: settings)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answers.isEmpty })
        await r.detector.stop()
        #expect(try await r.store.detectedQuestions(r.meeting).isEmpty, "not kept: gone with the recording")
        await Self.ask(r, "When is the deadline for the design review?", at: 720, segment: 2)
        await Self.idle(r)
        #expect(r.backend.evidenceCalls == 1)
    }

    @Test func turningKeepOffDuringTheRecordingAppliesWhenItEnds() async throws {
        let r = try await Self.rig()   // starts keeping
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answers.isEmpty })
        var now = LiveAnswerSettings.running
        now.keepDetectedQuestions = false
        await r.detector.update(settings: now)
        await r.detector.stop()
        #expect(try await r.store.detectedQuestions(r.meeting).isEmpty, "the person turned keeping off before the recording ended")
    }

    @Test func theChoiceMadeWhenStoppingWinsOverASettingsUpdateStillOnItsWay() async throws {
        var settings = LiveAnswerSettings.running
        settings.keepDetectedQuestions = false
        let r = try await Self.rig(settings: settings)   // the actor still has "do not keep"
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answers.isEmpty })
        await r.detector.stop(keepQuestions: true)   // the person turned Keep on and pressed Stop at once
        #expect(try await r.store.detectedQuestions(r.meeting).count == 1)
    }

    @Test func aQuestionHeardBeforeTheSwitchWentOffAndOnIsNotCheckedAfterwards() async throws {
        let backend = FakeAnswerBackend()
        let gate = StubGate()
        backend.evidenceGate = gate
        let r = try await Self.rig(backend: backend)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { backend.evidenceCalls == 1 })
        var off = LiveAnswerSettings.running
        off.enabled = false
        await r.detector.update(settings: off)
        await r.detector.update(settings: LiveAnswerSettings.running)
        gate.open()   // the evidence arrives after the switch came back on
        await Self.quiet(r, lines: 1)
        #expect(backend.checkTimes.isEmpty && r.events.answering.isEmpty, "the question belongs to the part of the recording that was switched off")
        await r.detector.stop()
    }

    @Test func aKeptQuestionSurvivesWhenTheSettingIsOff() async throws {
        var settings = LiveAnswerSettings.running
        settings.keepDetectedQuestions = false
        let r = try await Self.rig(settings: settings)
        await Self.ask(r, "Who is responsible for the vendor contract?", at: 700)
        #expect(await settle { !r.events.answers.isEmpty })
        let id = try #require(r.events.answers.first?.storedID)
        try await r.store.setQuestionKept(id, kept: true)
        await r.detector.stop()
        #expect(try await r.store.detectedQuestions(r.meeting).map(\.kept) == [true])
    }

    @Test func onlyTheNewestQueuedAnswerSurvivesAndTheOlderIsClosedAsStale() async throws {
        let backend = FakeAnswerBackend()
        let model = StubGate()
        backend.answerGate = model   // the first answer is being written until the test has queued the others behind it
        var timing = Self.fast
        timing.checkInterval = 0.01
        timing.cardInterval = 0.01
        let r = try await Self.rig(timing: timing, backend: backend)
        let questions = ["Who is responsible for the vendor contract?", "When is the deadline for the design review?", "Which supplier did we choose for the packaging?",
                         "How many people attended the workshop in March?"]
        for (i, q) in questions.enumerated() {
            await Self.ask(r, q, at: 700 + Double(i) * 10, segment: Int64(i + 1))
            #expect(await settle { await r.detector.counters.queued == i + 1 })
            if i == 0 { #expect(await settle { r.backend.answers.count == 1 }) }
        }
        // The second and third were replaced by the newer one while the first was still being written.
        #expect(await settle { await r.detector.counters.stale == 2 && r.backend.checkTimes.count == 4 })
        model.open()
        #expect(await settle { r.events.answers.count == 2 })
        let outcomes = try await r.store.detectedQuestions(r.meeting).map(\.outcome)
        #expect(outcomes.filter { $0 == .stale }.count == 2, "a question waiting behind a running answer is replaced by a newer one")
        await r.detector.stop()
    }
}

extension LiveAnswerSettings {
    /// The settings of a recording that runs live answers (`enabled` starts off like every default).
    static var running: LiveAnswerSettings {
        var settings = LiveAnswerSettings()
        settings.enabled = true
        return settings
    }
}
