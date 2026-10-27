// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// A model that answers the first question at once and keeps the second one working until it is cancelled.
private final class StubBackend: LiveAnswerBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var cancelled = false
    var answerCalls: Int { lock.withLock { calls } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

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
        .checked(QuestionCheck(kind: .information, question: question.candidate.text, answeredAloud: false))
    }
    func answer(_ rewrite: String, meetingID: Int64, request: AutoAskRequest) async throws -> AutoAnswerOutcome {
        let n = lock.withLock { () -> Int in calls += 1; return calls }
        if n == 1 { return .answered(Self.content) }
        do { try await Task.sleep(for: .seconds(60)) } catch {
            lock.withLock { cancelled = true }
            throw error
        }
        return .answered(Self.content)
    }
}

private func settle(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(240)
    while ContinuousClock.now < deadline {
        if await MainActor.run(body: condition) { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await MainActor.run(body: condition)
}

@Suite("App: the card and the detector together")
@MainActor
struct LiveAnswersBridgeTests {
    @Test func stoppingAnAnsweringRowStopsTheDetectorAndTheCardDoesNotComeBack() async throws {
        var timing = QuestionTiming()
        timing.settle = 0.05; timing.checkInterval = 0.05; timing.cardInterval = 0.05; timing.staleAfter = 600; timing.lateAfter = 60; timing.dropAfter = 120
        let model = LiveAnswersModel()
        model.announce = { _ in }
        let bridge = LiveAnswersBridge(model: model)
        let backend = StubBackend()
        let detector = QuestionDetector(backend: backend, store: nil, meetingID: 1, meetingLocale: "en-US", settings: { var on = LiveAnswerSettings(); on.enabled = true; return on }(), timing: timing,
                                        onEvent: bridge.send)
        bridge.detector = detector
        await detector.ingest(QuestionLine(segmentID: 1, channel: .others, start: 700, end: 703, text: "What was the budget we agreed for the second quarter?"))
        #expect(await settle { model.rows.count == 1 })
        await detector.ingest(QuestionLine(segmentID: 2, channel: .others, start: 740, end: 743, text: "When is the deadline for the design review?"))
        #expect(await settle { model.isWorking })
        let working = try #require(model.working.first)
        model.stopWorking()
        #expect(await settle { backend.wasCancelled }, "the stop reached the detector and cancelled the answer")
        // The detector has closed the cancelled answer; events reach the model in order, so once a marker sent after them is on screen
        // everything the detector said before has been applied.
        var idle = false
        for _ in 0..<500 where !idle {
            idle = await detector.isIdle
            if !idle { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(idle)
        let marker = AnswerRow(question: "Marker?", channel: .others, t: 2, content: StubBackend.content)
        bridge.send(.answer(marker))
        #expect(await settle { model.rows.contains { $0.id == marker.id } })
        #expect(model.rows.count == 2 && !model.rows.contains { $0.id == working.id }, "and the row did not come back")
        bridge.finish()
        await detector.stop()
    }

    @Test func whatTheDetectorSaysAfterTheRecordingEndedIsNotShown() async throws {
        let model = LiveAnswersModel()
        let bridge = LiveAnswersBridge(model: model)
        bridge.finish()
        bridge.send(.answer(AnswerRow(question: "Late?", channel: .others, t: 1, content: StubBackend.content)))
        // The stream is closed: nothing sent after `finish()` can reach the model, whenever its consumer runs.
        for _ in 0..<20 { await Task.yield() }
        #expect(model.rows.isEmpty)
    }
}
