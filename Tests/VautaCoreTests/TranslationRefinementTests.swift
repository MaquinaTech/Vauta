// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A server translator that answers "R(text)" after a delay and remembers its requests.
final class StubRefiner: RefiningTranslator, @unchecked Sendable {
    struct Call: Sendable { let text: String; let context: [TranslationExample] }
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _cancelled: [String] = []
    private var _active = 0
    private var _maxActive = 0
    var delay: Duration = .milliseconds(5)
    var delays: [String: Duration] = [:]
    var failing: Set<String> = []
    var tag = ""
    /// When set, a request waits for the test to open it instead of sleeping `delay` (`holds`: only the requests of those texts).
    var hold: StubGate? { get { lock.withLock { _hold } } set { lock.withLock { _hold = newValue } } }
    var holds: [String: StubGate] { get { lock.withLock { _holds } } set { lock.withLock { _holds = newValue } } }
    private var _hold: StubGate?
    private var _holds: [String: StubGate] = [:]

    var calls: [Call] { lock.withLock { _calls } }
    var cancelled: [String] { lock.withLock { _cancelled } }
    var maxConcurrent: Int { lock.withLock { _maxActive } }

    func refine(_ text: String, context: [TranslationExample]) async throws -> String {
        lock.withLock {
            _calls.append(Call(text: text, context: context))
            _active += 1
            _maxActive = max(_maxActive, _active)
        }
        defer { lock.withLock { _active -= 1 } }
        do {
            if let gate = hold ?? holds[text] { try await gate.wait() } else { try await Task.sleep(for: delays[text] ?? delay) }
        } catch {
            lock.withLock { _cancelled.append(text) }
            throw error
        }
        if failing.contains(text) { throw StubTranslator.Failure() }
        return "R\(tag)(\(text))"
    }
}

/// A live translator with Apple's stub and a server stub that can be switched off.
struct RefinementRig {
    let backend = StubBackend()
    let recorder = CaptionRecorder()
    let refiner = StubRefiner()
    let translator: LiveTranslator

    init(refiner enabled: Bool = true, tuning: LiveTranslator.Tuning = .refining) {
        let recorder = recorder, refiner = refiner
        let refine: LiveTranslator.Refiner = { _ in enabled ? refiner : nil }
        translator = LiveTranslator(backend: backend, tuning: tuning, refiner: refine) { recorder.addFinal($0) }
        recorder.watch(translator.snapshots)
    }

    func start(target: Locale.Language = spanish) async {
        await translator.configure(source: english, target: target)
    }

    /// The text last stored for `key`, and whether it came from the server.
    func stored(_ key: Int) -> FinalTranslation? { recorder.finals.last { $0.key == key } }
}

extension LiveTranslator.Tuning {
    static var refining: LiveTranslator.Tuning {
        var tuning = LiveTranslator.Tuning.fast
        // Never reached in a test that is not about the budget; tests about the budget set their own.
        tuning.refineBudget = .seconds(3_600)
        return tuning
    }
}

@Suite("Live Translation: refinement by the model server")
struct TranslationRefinementTests {
    @Test func theServerVersionReplacesAppleInPlaceAndIsStored() async {
        let rig = RefinementRig()
        await rig.start()
        rig.translator.submit(spoken("the plan is ready", final: true), key: 1)
        await eventually("the refined translation") { rig.recorder.finals.contains { $0.isRefined } }
        // Apple's text was stored first; the server's replaces it under the same key.
        #expect(rig.recorder.finals.map(\.text) == ["«the plan is ready»", "R(the plan is ready)"])
        #expect(rig.recorder.finals.map(\.key) == [1, 1])
        await eventually("the caption") { rig.recorder.latest?.lines.last?.translation == "R(the plan is ready)" }
        let line = rig.recorder.latest?.lines.last
        #expect(line?.isRefined == true && line?.state == .final)
        #expect(rig.recorder.latest?.refinement == .improved)
        // The same line (same id), not a new one: the view updates it in place.
        #expect(Set(rig.recorder.snapshots.flatMap(\.lines).map(\.id)).count == 1)
        await rig.translator.stop()
    }

    @Test func partialsAndTheAppleCaptionNeverWaitForTheServer() async {
        let rig = RefinementRig()
        let server = StubGate()
        rig.refiner.hold = server
        await rig.start()
        rig.translator.submit(spoken("we need to ship the release"), key: 0)
        await eventually("the partial") { rig.recorder.latest?.lines.last?.translation == "«we need to ship the release»" }
        rig.translator.submit(spoken("we need to ship the release", final: true), key: 1)
        await eventually("Apple's final") { rig.recorder.finals.count == 1 }
        #expect(rig.recorder.latest?.lines.last?.isRefined != true)
        await eventually("the request") { !rig.refiner.calls.isEmpty }
        #expect(rig.refiner.calls.map(\.text) == ["we need to ship the release"], "only finals go to the server")
        server.open()
        await rig.translator.stop()
    }

    @Test func aSlowServerKeepsApple() async {
        var tuning = LiveTranslator.Tuning.refining
        tuning.refineBudget = .milliseconds(80)
        tuning.refineLateBound = .milliseconds(250)
        let rig = RefinementRig(tuning: tuning)
        rig.refiner.delay = .untilCancelled
        await rig.start()
        rig.translator.submit(spoken("too slow for the budget", final: true), key: 1)
        await eventually("the budget to pass") { rig.recorder.latest?.refinement == .unavailable }
        #expect(rig.recorder.finals.map(\.text) == ["«too slow for the budget»"])
        #expect(rig.recorder.latest?.lines.last?.translation == "«too slow for the budget»")
        #expect(rig.recorder.latest?.lines.last?.isRefined == false)
        await eventually("the request to be given up at the bound") { !rig.refiner.cancelled.isEmpty }
        await rig.translator.stop()
    }

    @Test func aFailingServerKeepsAppleWithoutAlerts() async {
        let rig = RefinementRig()
        rig.refiner.failing = ["this one fails"]
        await rig.start()
        rig.translator.submit(spoken("this one fails", final: true), key: 1)
        await eventually("the status") { rig.recorder.latest?.refinement == .unavailable }
        #expect(rig.recorder.finals.map(\.text) == ["«this one fails»"])
        // The next sentence is tried again and the indicator recovers.
        rig.translator.submit(spoken("this one works", final: true), key: 2)
        await eventually("recovery") { rig.recorder.latest?.refinement == .improved }
        #expect(rig.stored(2)?.text == "R(this one works)" && rig.stored(1)?.isRefined == false)
        await rig.translator.stop()
    }

    @Test func afterRepeatedFailuresTheServerIsLeftAloneForAWhile() async {
        var tuning = LiveTranslator.Tuning.refining
        tuning.refineFailuresBeforePause = 2
        tuning.refinePause = .seconds(30)
        // One at a time: the third sentence cannot start before the second one's failure is counted.
        tuning.refineInFlight = 1
        let rig = RefinementRig(tuning: tuning)
        rig.refiner.failing = ["a one", "b two", "c three", "d four"]
        await rig.start()
        for (key, text) in ["a one", "b two", "c three", "d four"].enumerated() {
            rig.translator.submit(spoken(text, final: true), key: key + 1)
            await eventually("Apple's \(text)") { rig.recorder.finals.count == key + 1 }
            // The failure of a sent sentence is counted before the next one is submitted (the pause starts after the second).
            if key < 2 { let sent = key + 1; await eventually("the failure of \(text) counted") { await rig.translator.refineFailures == sent } }
        }
        #expect(rig.refiner.calls.map(\.text) == ["a one", "b two"], "the third and fourth were not sent")
        await rig.translator.stop()
    }

    @Test func eachSegmentIsStoredAppleFirstThenRefinedAndEachGetsItsOwnContext() async {
        let rig = RefinementRig()
        rig.refiner.delays = ["first sentence": .milliseconds(120), "second sentence": .milliseconds(10), "third sentence": .milliseconds(10)]
        await rig.start()
        for (key, text) in ["first sentence", "second sentence", "third sentence"].enumerated() {
            rig.translator.submit(spoken(text, final: true), key: key + 1)
        }
        await eventually("three refined") { rig.recorder.finals.filter(\.isRefined).count == 3 }
        // Two requests run at once, so they may reach the server in either order; the context is fixed when each starts.
        let byText = Dictionary(uniqueKeysWithValues: rig.refiner.calls.map { ($0.text, $0.context) })
        #expect(byText["first sentence"]?.isEmpty == true)
        #expect(byText["second sentence"]?.map(\.source) == ["first sentence"])
        #expect(byText["third sentence"]?.map(\.source) == ["first sentence", "second sentence"])
        for key in 1...3 {
            let ofKey = rig.recorder.finals.filter { $0.key == key }
            #expect(ofKey.map(\.isRefined) == [false, true], "Apple's text first, then the server's, for segment \(key)")
        }
        #expect(rig.refiner.maxConcurrent <= 2)
        await rig.translator.stop()
    }

    @Test func atMostTheConfiguredNumberOfRequestsAreInFlight() async {
        var tuning = LiveTranslator.Tuning.refining
        tuning.refineInFlight = 1
        tuning.refineBudget = .seconds(3_600)
        let rig = RefinementRig(tuning: tuning)
        rig.refiner.delay = .milliseconds(40)
        await rig.start()
        for key in 1...4 { rig.translator.submit(spoken("sentence \(key) here", final: true), key: key) }
        await eventually("all refined") { rig.recorder.finals.filter(\.isRefined).count == 4 }
        #expect(rig.refiner.maxConcurrent == 1)
        await rig.translator.stop()
    }

    @Test func aSentenceThatWaitedItsWholeBudgetInTheQueueIsNotSent() async {
        var tuning = LiveTranslator.Tuning.refining
        tuning.refineInFlight = 1
        tuning.refineBudget = .milliseconds(100)
        let rig = RefinementRig(tuning: tuning)
        rig.refiner.delay = .untilCancelled
        await rig.start()
        rig.translator.submit(spoken("hold the slot", final: true), key: 1)
        rig.translator.submit(spoken("waits too long", final: true), key: 2)
        await eventually("the first to time out") { rig.recorder.latest?.refinement == .unavailable }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.refiner.calls.map(\.text) == ["hold the slot"])
        await rig.translator.stop()
    }

    @Test func pausingCancelsWhatIsInFlightAndNothingArrivesLater() async {
        let rig = RefinementRig()
        let server = StubGate()
        rig.refiner.hold = server
        await rig.start()
        rig.translator.submit(spoken("cancel me please", final: true), key: 1)
        await eventually("the request") { !rig.refiner.calls.isEmpty }
        await rig.translator.setPaused(true)
        await eventually("the request cancelled") { rig.refiner.cancelled == ["cancel me please"] }
        server.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.recorder.finals.allSatisfy { !$0.isRefined })
        await rig.translator.stop()
    }

    @Test func stoppingCancelsAndDropsLateAnswers() async {
        let rig = RefinementRig()
        let server = StubGate()
        rig.refiner.hold = server
        await rig.start()
        rig.translator.submit(spoken("stop right now", final: true), key: 1)
        await eventually("the request") { !rig.refiner.calls.isEmpty }
        await rig.translator.stop()
        await eventually("the request cancelled") { rig.refiner.cancelled == ["stop right now"] }
        server.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.recorder.finals.allSatisfy { !$0.isRefined })
    }

    @Test func changingThePairMidFlightDropsTheOldAnswerAndNeverMixesLanguages() async {
        let rig = RefinementRig()
        let server = StubGate()
        rig.refiner.hold = server
        await rig.start(target: spanish)
        rig.translator.submit(spoken("hello everyone", final: true), key: 1)
        await eventually("the request") { !rig.refiner.calls.isEmpty }
        await rig.translator.configure(source: english, target: french)
        // The Spanish request was cancelled by the change (so it can never be stored); the server answers the French one.
        await eventually("the Spanish request cancelled") { !rig.refiner.cancelled.isEmpty }
        server.open()
        await eventually("French refinement") { rig.recorder.finals.contains { $0.language == "fr" && $0.isRefined } }
        #expect(rig.recorder.finals.filter { $0.language == "es" }.allSatisfy { !$0.isRefined })
        await rig.translator.stop()
    }

    @Test func aRefinedCaptionTranslatedAgainByAppleForANewPairIsNoLongerMarkedRefined() async {
        let rig = RefinementRig()
        await rig.start(target: spanish)
        rig.translator.submit(spoken("hello everyone", final: true), key: 1)
        await eventually("the refined caption") { rig.recorder.latest?.lines.last?.isRefined == true }
        // The server is slower than the budget now: the new pair's caption stays Apple's.
        rig.refiner.delay = .untilCancelled
        await rig.translator.configure(source: english, target: french)
        await eventually("Apple's French caption") {
            let line = rig.recorder.latest?.lines.last
            return rig.recorder.finals.contains { $0.language == "fr" } && line?.state == .final
                && line?.translation.hasPrefix("R(") == false
        }
        #expect(rig.recorder.latest?.lines.last?.isRefined == false)
        await rig.translator.stop()
    }

    @Test func contextIsTheThreePreviousSentencesWithTheirRefinedTranslations() async {
        let rig = RefinementRig()
        await rig.start()
        let sentences = ["one alpha", "two beta", "three gamma", "four delta", "five epsilon"]
        for (index, text) in sentences.enumerated() {
            rig.translator.submit(spoken(text, final: true), key: index + 1)
            await eventually("\(text) refined") { rig.stored(index + 1)?.isRefined == true }
        }
        let calls = rig.refiner.calls
        #expect(calls[0].context.isEmpty)
        #expect(calls[1].context == [TranslationExample(source: "one alpha", translation: "R(one alpha)")])
        #expect(calls[4].context == [TranslationExample(source: "two beta", translation: "R(two beta)"),
                                     TranslationExample(source: "three gamma", translation: "R(three gamma)"),
                                     TranslationExample(source: "four delta", translation: "R(four delta)")])
        await rig.translator.stop()
    }

    @Test func contextNeverIncludesOtherChannelsAndFallsBackToApple() async {
        let rig = RefinementRig()
        let slowOne = StubGate()
        rig.refiner.holds = ["slow earlier one": slowOne]
        await rig.start()
        rig.translator.submit(spoken("my private words", final: true, channel: .me), key: 1)
        rig.translator.submit(spoken("slow earlier one", final: true), key: 2)
        rig.translator.submit(spoken("quick later one", final: true), key: 3)
        await eventually("both requests") { rig.refiner.calls.count == 2 }
        let byText = Dictionary(uniqueKeysWithValues: rig.refiner.calls.map { ($0.text, $0.context) })
        #expect(byText["slow earlier one"]?.isEmpty == true, "the Me channel is not context")
        // The earlier sentence is still with the server: its Apple translation is the context.
        #expect(byText["quick later one"] == [TranslationExample(source: "slow earlier one", translation: "«slow earlier one»")])
        #expect(rig.refiner.calls.flatMap(\.context).allSatisfy { !$0.source.contains("private") })
        slowOne.open()
        await rig.translator.stop()
    }

    @Test func noServerOrRefinementOffMeansNoRequestsAndAQuietStatus() async {
        let rig = RefinementRig(refiner: false)
        await rig.start()
        rig.translator.submit(spoken("nothing to improve", final: true), key: 1)
        await eventually("Apple's final") { rig.recorder.finals.count == 1 }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.refiner.calls.isEmpty)
        #expect(rig.recorder.latest?.refinement == .off)
        #expect(rig.recorder.finals.map(\.text) == ["«nothing to improve»"])
        await rig.translator.stop()
    }

    @Test func withoutARefinerTheTranslatorBehavesAsBefore() async {
        let rig = TranslationRig()
        await rig.start()
        rig.translator.submit(spoken("plain apple", final: true), key: 1)
        await eventually("final") { rig.recorder.finals.count == 1 }
        #expect(rig.recorder.finals[0].isRefined == false && rig.recorder.latest?.refinement == .off)
        await rig.translator.stop()
    }

    @Test func raceReturnsTheFirstOutcomeAndToleratesAnOperationThatIgnoresCancellation() async {
        let finished = SharedBox(false)
        let release = AsyncStream.makeStream(of: Void.self)
        let outcome = await LiveTranslator.race(budget: .milliseconds(60)) {
            // Ignores cancellation: keeps waiting after it, until the test lets it go.
            for await _ in release.stream { break }
            finished.mutate { $0 = true }
            return "late"
        }
        guard case .failed = outcome else { Issue.record("expected a timeout"); release.continuation.finish(); return }
        // The answer came back while the operation was still running: it did not wait for it (it could not: nothing lets it go yet).
        #expect(!finished.value, "the answer did not wait for the operation")
        release.continuation.finish()
    }
}
