// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Live Translation: pipeline")
struct TranslationPipelineTests {
    @Test func finalsAreTranslatedInOrderEvenWhenTheFirstIsSlow() async {
        let rig = TranslationRig()
        rig.backend.configure = { $0.delays = ["first sentence here": .milliseconds(80)] }
        await rig.start()
        rig.translator.submit(spoken("first sentence here", final: true), key: 1)
        rig.translator.submit(spoken("second one", final: true), key: 2)
        rig.translator.submit(spoken("third one", final: true), key: 3)
        await eventually("three finals") { rig.recorder.finals.count == 3 }
        #expect(rig.recorder.finals.map(\.key) == [1, 2, 3])
        #expect(rig.recorder.finals.map(\.text) == ["«first sentence here»", "«second one»", "«third one»"])
        #expect(rig.recorder.finals.allSatisfy { $0.language == "es" })
        await eventually("snapshot with the finals") { rig.recorder.latest?.lines.allSatisfy { $0.state == .final } == true && rig.recorder.latest?.lines.count == 3 }
        await rig.translator.stop()
    }

    @Test func aBacklogGoesThroughOneBatch() async {
        let rig = TranslationRig()
        rig.backend.configure = { $0.delay = .milliseconds(60) }
        await rig.start()
        for key in 1...5 { rig.translator.submit(spoken("sentence number \(key)", final: true), key: key) }
        await eventually("five finals") { rig.recorder.finals.count == 5 }
        #expect(rig.recorder.finals.map(\.key) == [1, 2, 3, 4, 5])
        #expect(rig.backend.last?.batches.isEmpty == false, "the queued sentences are translated together")
        await rig.translator.stop()
    }

    @Test func otherChannelsAreIgnored() async {
        let rig = TranslationRig()
        await rig.start()
        rig.translator.submit(spoken("my own words", final: true, channel: .me), key: 1)
        rig.translator.submit(spoken("their words", final: true), key: 2)
        await eventually("their final") { rig.recorder.finals.count == 1 }
        #expect(rig.backend.last?.calls == ["their words"])
        await rig.translator.stop()
    }

    @Test func growthRuleNeedsTwoWordsOrFifteenCharacters() async {
        let translator = LiveTranslator(backend: StubBackend()) { _ in }
        #expect(await translator.grewEnough(from: "", to: "Hello") == false)
        #expect(await translator.grewEnough(from: "", to: "Hello there") == true)
        #expect(await translator.grewEnough(from: "", to: "Internationalization") == true)
        #expect(await translator.grewEnough(from: "Hello there", to: "Hello there my") == false)
        #expect(await translator.grewEnough(from: "Hello there", to: "Hello there my friend") == true)
        #expect(await translator.grewEnough(from: "Hello there my friend", to: "Hello there my friend") == false)
        #expect(await translator.grewEnough(from: "Hello there my friend", to: "Hello") == false)
        // Languages written without spaces count characters, with a lower bar.
        #expect(await translator.grewEnough(from: "", to: "今日は会議") == false)
        #expect(await translator.grewEnough(from: "", to: "今日は会議を始めます") == true)
        await translator.stop()
    }

    @Test func aBurstOfPartialsIsTranslatedOnceAfterTheQuiet() async {
        let rig = TranslationRig()
        await rig.start()
        let words = ["we need", "we need to", "we need to ship", "we need to ship the", "we need to ship the release"]
        for text in words { rig.translator.submit(spoken(text), key: 0) }
        await eventually("the partial translation") { rig.recorder.latest?.lines.last?.translation == "«we need to ship the release»" }
        #expect(rig.backend.last?.calls == ["we need to ship the release"])
        #expect(rig.recorder.latest?.lines.last?.state == .partial)
        await rig.translator.stop()
    }

    @Test func smallGrowthDoesNotTranslateAgain() async {
        let rig = TranslationRig()
        await rig.start()
        rig.translator.submit(spoken("we need to ship"), key: 0)
        await eventually("first partial") { rig.backend.last?.calls.count == 1 }
        rig.translator.submit(spoken("we need to ship it"), key: 0)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.backend.last?.calls.count == 1, "one extra word is not worth another translation")
        // The original keeps following the speaker.
        await eventually("the original follows") { rig.recorder.latest?.lines.last?.original == "we need to ship it" }
        rig.translator.submit(spoken("we need to ship it by Friday afternoon please"), key: 0)
        await eventually("grown partial") { rig.backend.last?.calls.count == 2 }
        await rig.translator.stop()
    }

    @Test func aNewerPartialCancelsTheStaleJob() async {
        let rig = TranslationRig()
        rig.backend.configure = { $0.delays = ["the old partial text": .untilCancelled] }
        await rig.start()
        rig.translator.submit(spoken("the old partial text"), key: 0)
        await eventually("job started") { rig.backend.last?.calls == ["the old partial text"] }
        rig.translator.submit(spoken("the old partial text and much more of it"), key: 0)
        await eventually("stale job cancelled") { rig.backend.last?.cancelled == ["the old partial text"] }
        await eventually("new translation shown") { rig.recorder.latest?.lines.last?.translation == "«the old partial text and much more of it»" }
        #expect(rig.backend.last?.maxConcurrent == 1, "never two partial jobs at once")
        #expect(rig.recorder.snapshots.allSatisfy { $0.lines.last?.translation != "«the old partial text»" })
        await rig.translator.stop()
    }

    @Test func aFinalTakesOverThePartialsLineAndItsProvisionalText() async {
        let rig = TranslationRig()
        // The final is held until the test has seen it pending: with a delay, a loaded Mac could let it finish first, and the
        // stream keeps only the newest snapshot, so the pending one would never be seen.
        let hold = StubGate()
        rig.backend.configure = { $0.gates = ["good morning to everyone here": hold] }
        await rig.start()
        rig.translator.submit(spoken("good morning to everyone"), key: 0)
        await eventually("partial translated") { rig.recorder.latest?.lines.last?.translation == "«good morning to everyone»" }
        let partialID = rig.recorder.latest?.lines.last?.id
        rig.translator.submit(spoken("good morning to everyone here", final: true), key: 7)
        await eventually("final pending") {
            guard let line = rig.recorder.latest?.lines.last else { return false }
            return line.state == .translating && line.id == partialID && line.translation == "«good morning to everyone»"
        }
        hold.open()
        await eventually("final done") { rig.recorder.latest?.lines.last?.state == .final }
        #expect(rig.recorder.latest?.lines.count == 1)
        #expect(rig.recorder.latest?.lines.last?.id == partialID, "the line is updated in place")
        #expect(rig.recorder.latest?.lines.last?.translation == "«good morning to everyone here»")
        await rig.translator.stop()
    }

    @Test func repeatedSentencesComeFromTheCache() async {
        let rig = TranslationRig()
        await rig.start()
        rig.translator.submit(spoken("Thank you very much", final: true), key: 1)
        await eventually("first") { rig.recorder.finals.count == 1 }
        rig.translator.submit(spoken("Thank you very much", final: true), key: 2)
        await eventually("second") { rig.recorder.finals.count == 2 }
        #expect(rig.backend.last?.calls == ["Thank you very much"])
        #expect(rig.recorder.finals.map(\.text) == ["«Thank you very much»", "«Thank you very much»"])
        await rig.translator.stop()
    }

    @Test func cacheEvictsTheLeastRecentlyUsed() {
        var cache = TranslationCache(capacity: 2)
        cache.insert("a", for: "A")
        cache.insert("b", for: "B")
        _ = cache.value(for: "A")
        cache.insert("c", for: "C")
        #expect(cache.value(for: "A") == "a")
        #expect(cache.value(for: "B") == nil)
        #expect(cache.value(for: "C") == "c")
        #expect(cache.count == 2)
    }

    @Test func publicationIsCoalesced() async {
        var tuning = LiveTranslator.Tuning.fast
        tuning.publishInterval = .milliseconds(100)
        let rig = TranslationRig(tuning: tuning)
        await rig.start()
        let start = ContinuousClock.now
        for i in 0..<200 {
            rig.translator.submit(spoken("word number \(i) keeps growing"), key: 0)
            try? await Task.sleep(for: .milliseconds(2))
        }
        await eventually("last text") { rig.recorder.latest?.lines.last?.original == "word number 199 keeps growing" }
        let elapsed = ContinuousClock.now - start
        let snapshots = rig.recorder.times
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(Double(snapshots.count) <= seconds * 10 + 2, "at most ~10 publications per second, got \(snapshots.count) in \(seconds) s")
        #expect(snapshots.count >= 2)
        // Gaps between receipts are not checked: they are measured by a second task, and a late
        // reader can see two publications back to back. The count above is what coalescing guarantees.
        await rig.translator.stop()
    }

    @Test func changingTheTargetMidMeetingTranslatesTheRecentCaptionsAgain() async {
        let rig = TranslationRig()
        await rig.start(target: spanish)
        rig.translator.submit(spoken("one sentence", final: true), key: 1)
        rig.translator.submit(spoken("another sentence", final: true), key: 2)
        await eventually("spanish finals") { rig.recorder.finals.count == 2 }
        await rig.start(target: french)
        await eventually("french finals") { rig.recorder.finals.filter { $0.language == "fr" }.count == 2 }
        #expect(rig.backend.made.map(\.pair) == ["en>es", "en>fr"], "one translator per pair")
        #expect(rig.backend.made[1].translator.calls == ["one sentence", "another sentence"], "the cache of the old pair is not reused")
        rig.translator.submit(spoken("a third", final: true), key: 3)
        await eventually("third") { rig.recorder.finals.last?.key == 3 }
        #expect(rig.recorder.finals.last?.language == "fr")
        await eventually("french pair published") { rig.recorder.latest?.pair?.target == french }
        await rig.translator.stop()
    }

    @Test func aTargetChangeWhileABatchIsBeingStoredNeverLabelsOldTextWithTheNewLanguage() async {
        let backend = StubBackend()
        backend.tagsTarget = true
        backend.makeDelay = .milliseconds(80)
        let recorder = CaptionRecorder()
        let firstStored = AsyncStream.makeStream(of: Void.self)
        let translator = LiveTranslator(backend: backend, tuning: .fast) { final in
            recorder.addFinal(final)
            if final.key == 1, final.language == "es" {
                // Storing is slow: the target changes meanwhile.
                firstStored.continuation.yield()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        recorder.watch(translator.snapshots)
        let configuring = Task { await translator.configure(source: english, target: spanish) }
        try? await Task.sleep(for: .milliseconds(20))
        for key in 1...3 { translator.submit(spoken("sentence number \(key)", final: true), key: key) }
        await configuring.value
        for await _ in firstStored.stream { break }
        await translator.configure(source: english, target: french)
        await eventually("french finals") { Set(recorder.finals.filter { $0.language == "fr" }.map(\.key)) == [1, 2, 3] }
        try? await Task.sleep(for: .milliseconds(100))
        for final in recorder.finals {
            #expect(final.text.hasPrefix("«\(final.language):"), "\(final.key) stored as \(final.language) but is \(final.text)")
        }
        #expect(recorder.finals.filter { $0.language == "fr" }.count == 3, "one French row per sentence")
        await translator.stop()
    }

    @Test func aTargetChangeBeforeTheTranslatorIsReadyKeepsTheWholeBacklog() async {
        let rig = TranslationRig()
        rig.backend.makeDelay = .milliseconds(150)
        let configuring = Task { await rig.translator.configure(source: english, target: spanish) }
        try? await Task.sleep(for: .milliseconds(20))
        for key in 1...5 { rig.translator.submit(spoken("sentence number \(key)", final: true), key: key) }
        try? await Task.sleep(for: .milliseconds(20))
        rig.backend.makeDelay = .zero
        await rig.start(target: french)
        await configuring.value
        await eventually("all five in french") { rig.recorder.finals.map(\.key) == [1, 2, 3, 4, 5] }
        #expect(rig.recorder.finals.allSatisfy { $0.language == "fr" })
        await eventually("no caption left translating") { rig.recorder.latest?.lines.allSatisfy { $0.state == .final } == true }
        await rig.translator.stop()
    }

    @Test func pausingStopsAllWorkAndResumingContinues() async {
        let rig = TranslationRig()
        await rig.start()
        await rig.translator.setPaused(true)
        await eventually("paused status") { rig.recorder.latest?.status == .paused }
        rig.translator.submit(spoken("said while paused here", final: true), key: 1)
        rig.translator.submit(spoken("partial while paused here"), key: 0)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.backend.last?.calls.isEmpty == true)
        #expect(rig.recorder.finals.isEmpty, "nothing is stored while paused")
        await rig.translator.setPaused(false)
        await eventually("listening again") { rig.recorder.latest?.status == .listening }
        rig.translator.submit(spoken("said after resuming", final: true), key: 2)
        await eventually("final after resume") { rig.recorder.finals.count == 1 }
        #expect(rig.recorder.finals.first?.key == 2)
        await rig.translator.stop()
    }

    @Test func stoppingEndsTheStreamAndIgnoresLaterInput() async {
        let rig = TranslationRig()
        await rig.start()
        await rig.translator.stop()
        rig.translator.submit(spoken("too late for this", final: true), key: 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.recorder.finals.isEmpty)
        #expect(rig.backend.last?.calls.isEmpty == true)
    }

    @Test func finishingWaitsForTheFinalsInFlight() async {
        let rig = TranslationRig()
        rig.backend.configure = { $0.delay = .milliseconds(60) }
        await rig.start()
        rig.translator.submit(spoken("the very last sentence", final: true), key: 9)
        await rig.translator.finish(maxWait: .seconds(3_600))
        #expect(rig.recorder.finals.map(\.key) == [9])
    }

    @Test func finishingGivesUpAfterTheBudget() async {
        let rig = TranslationRig()
        rig.backend.configure = { $0.delay = .untilCancelled }
        await rig.start()
        rig.translator.submit(spoken("this never completes", final: true), key: 1)
        // The translation never ends by itself: `finish` returning at all is the proof that it gave up after its budget.
        await rig.translator.finish(maxWait: .milliseconds(150))
        #expect(rig.recorder.finals.isEmpty)
    }

    @Test func statesWithoutATranslatorDoNoWork() async {
        for (availability, expected) in [(PairAvailability.unsupported, CaptionStatus.unsupported), (.downloadable, .needsDownload)] {
            let rig = TranslationRig()
            rig.backend.statuses["en>es"] = availability
            await rig.start()
            rig.translator.submit(spoken("hello there everyone", final: true), key: 1)
            // Under load the status can take longer than a fixed sleep to arrive.
            await eventually("status \(expected)") { rig.recorder.latest?.status == expected }
            #expect(rig.recorder.latest?.status == expected)
            #expect(rig.backend.made.isEmpty, "no translator is created")
            #expect(rig.recorder.finals.isEmpty)
            await rig.translator.stop()
        }
    }

    @Test func sameLanguageIsOff() async {
        let rig = TranslationRig()
        await rig.translator.configure(source: english, target: Locale.Language(identifier: "en-GB"))
        #expect(rig.recorder.latest == nil || rig.recorder.latest?.status == .sameLanguage)
        await eventually("same language status") { rig.recorder.latest?.status == .sameLanguage }
        #expect(rig.backend.made.isEmpty)
        await rig.translator.stop()
    }

    @Test func downloadingIsShownAndRetryStartsTheTranslator() async {
        let rig = TranslationRig()
        rig.backend.statuses["en>es"] = .downloadable
        await rig.start()
        await rig.translator.setDownloading(true)
        await eventually("downloading") { rig.recorder.latest?.status == .downloading }
        rig.backend.statuses["en>es"] = .installed
        await rig.translator.retry()
        await eventually("listening") { rig.recorder.latest?.status == .listening }
        rig.translator.submit(spoken("now it works fine", final: true), key: 1)
        await eventually("translated") { rig.recorder.finals.count == 1 }
        await rig.translator.stop()
    }

    @Test func repeatedFailuresStopTheFeatureWithAClearStatus() async {
        let rig = TranslationRig()
        rig.backend.configure = { $0.failing = ["bad one", "bad two", "bad three"] }
        await rig.start()
        for (i, text) in ["bad one", "bad two", "bad three"].enumerated() {
            rig.translator.submit(spoken(text, final: true), key: i)
            try? await Task.sleep(for: .milliseconds(30))
        }
        await eventually("failed status") { rig.recorder.latest?.status == .failed }
        #expect(rig.recorder.finals.isEmpty)
        await rig.translator.stop()
    }

    @Test func oneFailedSentenceIsSkipped() async {
        let rig = TranslationRig()
        rig.backend.configure = { $0.failing = ["broken"] }
        await rig.start()
        rig.translator.submit(spoken("broken", final: true), key: 1)
        rig.translator.submit(spoken("fine sentence", final: true), key: 2)
        await eventually("the good one") { rig.recorder.finals.count == 1 }
        #expect(rig.recorder.finals.first?.key == 2)
        await eventually("still listening") { rig.recorder.latest?.status == .listening }
        await rig.translator.stop()
    }
}

@Suite("Live Translation: languages")
struct TranslationLanguageTests {
    @Test func theAutomaticTargetIsTheFirstPreferredLanguageThatDiffers() {
        let en = Locale.Language(identifier: "en-US")
        #expect(TranslationPair.automaticTarget(source: en, preferred: ["en-US", "es-ES", "fr-FR"])?.minimalIdentifier == "es")
        #expect(TranslationPair.automaticTarget(source: Locale.Language(identifier: "es-ES"), preferred: ["es-ES", "en-GB"])?.minimalIdentifier == "en-GB")
        #expect(TranslationPair.automaticTarget(source: en, preferred: ["en-GB", "en-US"]) == nil)
    }

    @Test func variantsOfOneLanguageAreTheSameButChineseScriptsAreNot() {
        #expect(Locale.Language(identifier: "en-US").isSameLanguage(as: Locale.Language(identifier: "en-GB")))
        #expect(!Locale.Language(identifier: "es").isSameLanguage(as: Locale.Language(identifier: "pt")))
        #expect(Locale.Language(identifier: "zh-Hans").isSameLanguage(as: Locale.Language(identifier: "zh-CN")))
        #expect(!Locale.Language(identifier: "zh-Hans").isSameLanguage(as: Locale.Language(identifier: "zh-TW")))
        #expect(TranslationPair(source: Locale.Language(identifier: "en-US"), target: Locale.Language(identifier: "en-AU")).isIdentity)
    }

    @Test func pickersCollapseRegionalVariants() {
        let ids = ["en", "en-GB", "en-AU", "es", "es-MX", "pt", "pt-PT", "zh", "zh-TW", "zh-HK", "ar-AE", "ar-SA", "ja"]
        let picked = pickerLanguages(ids.map(Locale.Language.init(identifier:))).map(\.minimalIdentifier)
        #expect(picked == ["en", "es", "pt", "pt-PT", "zh", "zh-TW", "zh-HK", "ar-AE", "ar-SA", "ja"])
    }

    @Test func targetsExcludeTheSpokenLanguageAndUnsupportedPairs() async {
        let backend = StubBackend()
        backend.statuses["en>fr"] = .downloadable
        backend.statuses["en>de"] = .unsupported
        let targets = await backend.targets(from: english, among: ["en", "es", "fr", "de"].map(Locale.Language.init(identifier:)))
        #expect(Set(targets.map(\.id)) == ["es", "fr"])
        #expect(targets.first { $0.id == "fr" }?.availability == .downloadable)
    }

    @Test func theStoredCodeIsShortAndStable() {
        #expect(Locale.Language(identifier: "es-ES").storageCode == "es")
        #expect(Locale.Language(identifier: "zh-Hans").storageCode == "zh-Hans" || Locale.Language(identifier: "zh-Hans").storageCode == "zh")
        #expect(TranslationPair(source: english, target: spanish).id == "en>es")
    }
}
