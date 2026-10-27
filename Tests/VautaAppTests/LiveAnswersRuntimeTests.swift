// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// A model that answers every question; counts what reached it.
private final class AlwaysAnswers: LiveAnswerBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _checks = 0
    var checks: Int { lock.withLock { _checks } }
    static let content = AutoAnswerContent(answer: "The budget was fifty thousand euros.",
                                           claims: [.init(text: "Budget", cites: [.init(kind: .thisMeeting, segmentID: 1, meetingID: 1, t: 12)])])
    func modelAvailable() async -> Bool { true }
    func usesIntegratedModel() async -> Bool { false }
    func evidence(text: String, locale: String, meetingID: Int64, segmentID: Int64?, sources: LiveAnswerSources, embed: Bool) async -> QuestionEvidence {
        var e = QuestionEvidence()
        e.passing = [.thisMeeting]
        e.best = .thisMeeting
        return e
    }
    func check(_ question: SettledQuestion, meetingID: Int64) async -> QuestionCheckResult {
        lock.withLock { _checks += 1 }
        return .checked(QuestionCheck(kind: .information, question: question.candidate.text, answeredAloud: false))
    }
    func answer(_ rewrite: String, meetingID: Int64, request: AutoAskRequest) async throws -> AutoAnswerOutcome { .answered(Self.content) }
}

private final class SwitchableBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LiveAnswerBackendKind? = .integrated
    var kind: LiveAnswerBackendKind? { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

/// The recorder's side of decision D16: what a running recording does when the model that answers changes in the middle of the meeting.
/// `RecorderModel` calls `LiveAnswersSync` for all of it; these tests drive the same functions with a switchable backend and a real
/// detector, so the settings the detector runs with, the card, the stored choice and the hint are all asserted.
@Suite("Live answers: the recording follows the model that answers")
@MainActor
struct LiveAnswersRuntimeTests {
    @MainActor private final class Rig {
        let suite = "vauta.test.liveruntime.\(UUID().uuidString)"
        let backend = SwitchableBackend()
        let preferences: Preferences
        let answers = LiveAnswersModel()
        let model = AlwaysAnswers()
        var running: LiveAnswerSettings?
        var detector: QuestionDetector!
        var bridge: LiveAnswersBridge!
        var updates: [Bool] = []
        /// The recorder puts a change of settings in the chain of lines, so a later line sees it.
        var chain: Task<Void, Never>?

        init(chosen: Bool? = true) {
            let defaults = UserDefaults(suiteName: suite)!
            preferences = Preferences(defaults: defaults, legacyInstall: false)
            preferences.liveAnswersBackend = { [backend] in backend.kind }
            if let chosen { preferences.liveAnswersEnabled = chosen }
            answers.announce = { _ in }
        }

        /// What `startLiveAnswers` does: the detector is made with the settings of the moment, enabled or not.
        func start() {
            var timing = QuestionTiming()
            timing.settle = 0.05; timing.checkInterval = 0.05; timing.cardInterval = 0.05; timing.staleAfter = 600; timing.lateAfter = 60; timing.dropAfter = 120
            running = preferences.liveAnswerSettings
            bridge = LiveAnswersBridge(model: answers, accepting: { [preferences] in preferences.liveAnswersActive })
            detector = QuestionDetector(backend: model, store: nil, meetingID: 1, meetingLocale: "en-US", settings: preferences.liveAnswerSettings, timing: timing,
                                        onEvent: bridge.send)
            bridge.detector = detector
        }

        /// What `considerQuestion` does with a final line.
        func line(_ n: Int, _ text: String) async {
            let result = LiveAnswersSync.admit(running: running, preferences: preferences, answers: answers) { [self] settings in
                running = settings
                updates.append(settings.enabled)
                let d = detector!
                let previous = chain
                chain = Task { await previous?.value; await d.update(settings: settings) }
            }
            running = result.settings
            await chain?.value
            guard result.ingest else { return }
            await detector.ingest(QuestionLine(segmentID: Int64(n), channel: .others, start: Double(n) * 30, end: Double(n) * 30 + 3, text: text))
        }

        func finish() async {
            bridge.finish()
            await detector.stop()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    private static let q1 = "What was the budget we agreed for the second quarter?"
    private static let q2 = "When is the deadline for the design review?"
    private static let q3 = "Who is going to write the summary of the meeting today?"

    private func settle(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(240)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aSwitchToAppleStopsTheDetectorClearsTheCardAndKeepsTheChoiceAndTheReturnResumes() async throws {
        let rig = Rig()
        rig.start()
        await rig.line(1, Self.q1)
        #expect(await settle { rig.answers.rows.count == 1 }, "on the integrated model the card appears")

        rig.backend.kind = .apple   // Gemma is gone and Apple stands in
        await rig.line(2, Self.q2)
        #expect(rig.running?.enabled == false && rig.updates == [false], "the detector was told to stop")
        #expect(rig.answers.rows.isEmpty && !rig.answers.isWorking, "the card was cleared")
        #expect(rig.preferences.liveAnswersChoice == true && rig.preferences.liveAnswersEnabled, "the stored choice stays")
        #expect(!rig.preferences.liveAnswersActive)
        let checksOnApple = rig.model.checks
        await rig.line(3, Self.q3)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.answers.rows.isEmpty && rig.model.checks == checksOnApple, "no line reached the detector while Apple answers, no card")

        rig.backend.kind = .integrated
        await rig.line(4, Self.q2)
        #expect(rig.running?.enabled == true && rig.updates == [false, true], "the return resumes the detector")
        #expect(await settle { rig.answers.rows.count == 1 }, "and the cards come back")
        await rig.finish()
    }

    @Test func aRecordingThatStartsOnAppleWithTheChoiceOnNeverRunsTheDetector() async throws {
        let rig = Rig()
        rig.backend.kind = .apple
        rig.answers.showsHint = false
        rig.start()
        #expect(rig.running?.enabled == false)
        await rig.line(1, Self.q1)
        await rig.line(2, Self.q2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.model.checks == 0 && rig.answers.rows.isEmpty && !rig.answers.isWorking && rig.answers.pause == nil)
        #expect(rig.updates.isEmpty, "nothing to change: it was disabled from the start")
        #expect(rig.preferences.liveAnswersChoice == true)
        await rig.finish()
    }

    @Test func aStopCausedByTheBackendDoesNotUseUpTheHintButTheSwitchDoes() async throws {
        let rig = Rig(chosen: nil)   // never chosen: nothing stored
        rig.answers.showsHint = true
        rig.preferences.liveAnswersChoice = true   // as if the hint's own "on" had been kept
        rig.start()
        rig.backend.kind = .apple
        await rig.line(1, Self.q1)
        #expect(!rig.answers.showsHint, "the hint goes with the feature")
        #expect(!rig.preferences.liveAnswersHintSeen, "but the person did not turn the feature off: it was the backend")
        await rig.finish()

        let off = Rig(chosen: true)
        off.answers.showsHint = true
        off.start()
        off.preferences.liveAnswersEnabled = false
        await off.line(1, Self.q1)
        #expect(!off.answers.showsHint && off.preferences.liveAnswersHintSeen, "the person turned it off: the hint is used up")
        await off.finish()
    }

    @Test func theSwitchMovesToStopInTheMiddleAndKeepsQuestionsFollowsThePreference() {
        let rig = Rig()
        rig.start()
        rig.preferences.liveAnswersKeepQuestions = false
        let settings = LiveAnswersSync.settingChanged(running: rig.running, preferences: rig.preferences, answers: rig.answers) { _ in }
        #expect(settings.enabled && settings.keepDetectedQuestions == false)
        UserDefaults(suiteName: rig.suite)?.removePersistentDomain(forName: rig.suite)
    }

    @Test func aPauseOnItsWayWhenAppleTakesOverNeverBringsTheLineBack() async throws {
        let rig = Rig()
        rig.start()
        rig.backend.kind = .apple
        // The detector said "paused" just before the switch; the event is still in the stream when the sync clears the card.
        rig.bridge.send(.paused(.modelUnavailable))
        let settings = LiveAnswersSync.settingChanged(running: rig.running, preferences: rig.preferences, answers: rig.answers) { s in
            let d = rig.detector!
            Task { await d.update(settings: s) }
        }
        rig.bridge.send(.paused(.modelUnavailable))
        #expect(!settings.enabled)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.answers.pause == nil && !rig.answers.isVisible, "no live-answer UI while Apple answers")
        await rig.finish()
    }

    @Test func aBackendChangeInTheMiddleOfARecordingStopsTheDetectorWithoutAFinalLine() async throws {
        let rig = Rig()
        rig.start()
        var last: LiveAnswerBackendKind?
        var updates: [Bool] = []
        func check(_ backend: LiveAnswerBackendKind, recording: Bool = true) -> LiveAnswerSettings? {
            LiveAnswersSync.backendMayHaveChanged(backend: backend, last: &last, recording: recording, running: rig.running,
                                                  preferences: rig.preferences, answers: rig.answers) { s in
                rig.running = s
                updates.append(s.enabled)
            }
        }
        rig.backend.kind = .integrated
        #expect(check(.integrated) != nil && rig.preferences.liveAnswersBackendTick == 1)
        #expect(check(.integrated) == nil && rig.preferences.liveAnswersBackendTick == 1, "no change: no tick, no update")
        rig.answers.apply(.paused(.modelUnavailable))
        updates = []
        rig.backend.kind = .apple
        #expect(check(.apple)?.enabled == false && updates == [false] && rig.preferences.liveAnswersBackendTick == 2)
        #expect(!rig.answers.isVisible, "the card was cleared without a final line")
        rig.backend.kind = .integrated
        #expect(check(.integrated)?.enabled == true && updates == [false, true])
        #expect(check(.apple, recording: false) == nil && rig.preferences.liveAnswersBackendTick == 4, "outside a recording only Settings is told")
        await rig.finish()
    }

    @Test func aFallbackNoticedOnlyAtAFinalLineTicksSettingsAndRemembersTheBackend() async throws {
        let rig = Rig()
        rig.start()
        var last: LiveAnswerBackendKind? = .integrated
        let ticks = rig.preferences.liveAnswersBackendTick
        // The engine marked the model damaged: no status change, so only the final line can notice Apple standing in.
        rig.backend.kind = .apple
        let result = LiveAnswersSync.lineArrived(backend: .apple, last: &last, running: rig.running, preferences: rig.preferences,
                                                 answers: rig.answers) { s in rig.running = s }
        #expect(!result.ingest && result.settings?.enabled == false && rig.running?.enabled == false)
        #expect(last == .apple && rig.preferences.liveAnswersBackendTick == ticks + 1, "Settings draws again and the backend is remembered")
        let again = LiveAnswersSync.lineArrived(backend: .apple, last: &last, running: rig.running, preferences: rig.preferences,
                                                answers: rig.answers) { s in rig.running = s }
        #expect(!again.ingest && rig.preferences.liveAnswersBackendTick == ticks + 1, "no new change, no new tick")
        await rig.finish()
    }

    @Test func theRecorderReportsTheAnsweringBackendAndOtherwiseTheOneTheSettingsPointTo() {
        #expect(LiveAnswersSync.backend(answering: .integrated, chat: .onDevice, liveTasks: .apple) == .integrated)
        #expect(LiveAnswersSync.backend(answering: nil, chat: .onDevice, liveTasks: .integrated) == .apple, "no service yet")
        #expect(LiveAnswersSync.backend(answering: nil, chat: .integrated, liveTasks: .apple) == .apple)
        #expect(LiveAnswersSync.backend(answering: nil, chat: .integrated, liveTasks: .integrated) == .integrated)
        #expect(LiveAnswersSync.backend(answering: nil, chat: .server, liveTasks: .apple) == .server)
    }

    @Test func savingWhileRecordingTellsTheRecorder() {
        let suite = "vauta.test.livetasks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IntegratedModelModel(defaults: defaults)
        var told = 0
        model.onLiveTasksChanged = { told += 1 }
        model.setLiveTasks(.apple)
        #expect(told == 1 && model.liveTasks == .apple && ModelProviderSettings.liveTasks(defaults: defaults) == .apple)
    }
}
