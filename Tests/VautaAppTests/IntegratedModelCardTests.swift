// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class AskKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// What Settings → Models says about the integrated model, built through the section (not through the text helpers directly).
@Suite("App: integrated model card")
@MainActor
struct IntegratedModelCardTests {
    @Test func theDeleteDialogNamesAppleIntelligenceOnlyWhereItIsAvailable() {
        let with = IntegratedModelSection.deleteDialogMessage(chosen: true, liveIntegrated: true, installedBytes: 4_200_000_000, appleAvailable: true)
        let without = IntegratedModelSection.deleteDialogMessage(chosen: true, liveIntegrated: true, installedBytes: 4_200_000_000, appleAvailable: false)
        #expect(with.contains("Apple Intelligence"))
        #expect(!without.contains("Apple Intelligence"), "\(without)")
        let notChosen = IntegratedModelSection.deleteDialogMessage(chosen: false, liveIntegrated: false, installedBytes: 0, appleAvailable: false)
        #expect(!notChosen.contains("Apple Intelligence"))
    }

    /// Since 2026-10-15: with Apple Intelligence for "While recording" the integrated model is idle, and the copy says so.
    @Test func theActivityLineSaysTheModelIsIdleWhenLiveWorkIsOnApple() {
        let idle = IntegratedModelText.activityWhileRecording(liveOnApple: true)
        #expect(idle.contains("stays idle") && idle.contains("take longer to start"), "\(idle)")
        #expect(IntegratedModelText.activityWhileRecording(liveOnApple: false) == IntegratedModelText.activityReading)
        #expect(!IntegratedModelText.readyLiveApple.contains("still reads"), "the description no longer promises background reading")
        #expect(IntegratedModelText.readyLiveApple.contains("idle"))
    }

    @Test func askShowsTheStageOfItsOwnQuestionAndNotTheStageOfAnotherJob() {
        var status = LLMService.Status()
        status.stage = .checkingAnswer
        status.activityIsAsk = true
        #expect(AskView.progressText(status: status, progressTokens: 0) == MinutesActivity.stageText(status))
        status.stage = .readingTranscript
        status.prefill = LLMService.PrefillProgress(done: 4_000, total: 10_000)
        let reading = AskView.progressText(status: status, progressTokens: 0)
        #expect(reading.hasPrefix("Reading the meeting") && reading.contains("40"), "\(reading)")
        // The minutes of another meeting reading its transcript must not show up in Ask.
        status.activityIsAsk = false
        #expect(AskView.progressText(status: status, progressTokens: 0).hasPrefix("The model is reading your meetings"))
        #expect(AskView.progressText(status: status, progressTokens: 10) == "Writing the answer…")
    }

    @Test func theMomentsOfANotYetAnswerAreListedInTheOrderTheyWereSaid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ask = AskModel(store: try MeetingStore(directory: dir, keyStore: AskKey()))
        for (id, start) in [(Int64(1), 504.0), (2, 152.0), (3, 30.0)] {
            ask.segments[id] = CitableSegment(id: id, channel: .others, start: start, text: "x")
            ask.segmentMeeting[id] = 7
        }
        let claims = [VerifiedAnswer.Claim(id: "a", text: "A", citations: [1, 2], verified: false), VerifiedAnswer.Claim(id: "b", text: "B", citations: [2, 3], verified: false)]
        #expect(ask.momentsInSpokenOrder(claims) == [3, 2, 1])
    }
}
