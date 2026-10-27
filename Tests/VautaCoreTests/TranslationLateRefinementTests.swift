// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Live Translation: late answers from the model server")
struct TranslationLateRefinementTests {
    private func tuning(budget: Int = 80, bound: Int = 3_600_000) -> LiveTranslator.Tuning {
        var tuning = LiveTranslator.Tuning.refining
        tuning.refineBudget = .milliseconds(budget)
        tuning.refineLateBound = .milliseconds(bound)
        return tuning
    }

    @Test func anAnswerAfterTheCaptionBudgetIsStoredButTheCaptionStays() async {
        let rig = RefinementRig(tuning: tuning())
        let server = StubGate()
        rig.refiner.hold = server
        await rig.start()
        rig.translator.submit(spoken("this one arrives late", final: true), key: 1)
        // The caption budget passes with the server still silent; only then does it answer.
        await eventually("the budget to pass") { rig.recorder.latest?.refinement == .unavailable }
        server.open()
        await eventually("the late answer is stored") { rig.recorder.finals.contains { $0.isRefined } }
        let stored = rig.stored(1)
        #expect(stored?.text == "R(this one arrives late)" && stored?.isRefined == true && stored?.source == "this one arrives late")
        // The caption on screen is still Apple's.
        #expect(rig.recorder.latest?.lines.last?.translation == "«this one arrives late»")
        #expect(rig.recorder.latest?.lines.last?.isRefined == false)
        #expect(rig.recorder.snapshots.flatMap(\.lines).allSatisfy { !$0.isRefined })
        await rig.translator.stop()
    }

    @Test func aRequestPastTheBoundIsGivenUpAndNothingIsStored() async {
        let rig = RefinementRig(tuning: tuning(bound: 250))
        rig.refiner.delay = .untilCancelled
        await rig.start()
        rig.translator.submit(spoken("never arrives", final: true), key: 1)
        await eventually("the request to be cancelled") { !rig.refiner.cancelled.isEmpty }
        #expect(rig.recorder.finals.map(\.text) == ["«never arrives»"])
        await rig.translator.stop()
    }

    @Test func aRequestInFlightWhenTheRecordingStopsFinishesAndIsStored() async {
        let rig = RefinementRig(tuning: tuning(budget: 300, bound: 3_600_000))
        let server = StubGate()
        rig.refiner.hold = server
        await rig.start()
        rig.translator.submit(spoken("said just before stopping", final: true), key: 1)
        await eventually("the request") { !rig.refiner.calls.isEmpty }
        // The server does not answer until after `finish` returned: stopping does not wait for it (it could not).
        await rig.translator.finish(maxWait: .milliseconds(100))
        #expect(rig.stored(1)?.isRefined != true)
        server.open()
        await rig.translator.waitForRefinements()
        #expect(rig.stored(1)?.text == "R(said just before stopping)")
        #expect(rig.refiner.cancelled.isEmpty)
    }

    @Test func aRequestStillMissingAtTheBoundAfterTheStopIsGivenUp() async {
        let rig = RefinementRig(tuning: tuning(budget: 100, bound: 300))
        rig.refiner.delay = .untilCancelled
        await rig.start()
        rig.translator.submit(spoken("stuck on the server", final: true), key: 1)
        await eventually("the request") { !rig.refiner.calls.isEmpty }
        await rig.translator.finish(maxWait: .milliseconds(100))
        await rig.translator.waitForRefinements()
        await eventually("given up at the bound") { rig.refiner.cancelled == ["stuck on the server"] }
        #expect(rig.stored(1)?.isRefined != true)
    }

    @Test func aHardStopStillCancelsWhatIsInFlight() async {
        let rig = RefinementRig(tuning: tuning(budget: 300))
        rig.refiner.delay = .untilCancelled
        await rig.start()
        rig.translator.submit(spoken("feature turned off", final: true), key: 1)
        await eventually("the request") { !rig.refiner.calls.isEmpty }
        await rig.translator.stop()
        await eventually("cancelled") { !rig.refiner.cancelled.isEmpty }
        await rig.translator.waitForRefinements()
        #expect(rig.stored(1)?.isRefined != true)
    }

    @Test func aPauseCancelsLateRequestsToo() async {
        let rig = RefinementRig(tuning: tuning(budget: 80))
        rig.refiner.delay = .untilCancelled
        await rig.start()
        rig.translator.submit(spoken("paused while late", final: true), key: 1)
        await eventually("the request") { !rig.refiner.calls.isEmpty }
        await eventually("past the caption budget: now a late request") { rig.recorder.latest?.refinement == .unavailable }
        await rig.translator.setPaused(true)
        await eventually("cancelled") { !rig.refiner.cancelled.isEmpty }
        #expect(rig.stored(1)?.isRefined != true)
        await rig.translator.stop()
    }

    @Test func aPairChangeCancelsLateRequests() async {
        let rig = RefinementRig(tuning: tuning(budget: 80))
        rig.refiner.delay = .untilCancelled
        await rig.start()
        rig.translator.submit(spoken("pair changes", final: true), key: 1)
        await eventually("the request") { !rig.refiner.calls.isEmpty }
        await eventually("past the caption budget") { rig.recorder.latest?.refinement == .unavailable }
        await rig.translator.configure(source: english, target: Locale.Language(identifier: "fr"))
        await eventually("cancelled") { !rig.refiner.cancelled.isEmpty }
        #expect(rig.recorder.finals.allSatisfy { !$0.isRefined })
        await rig.translator.stop()
    }
}
