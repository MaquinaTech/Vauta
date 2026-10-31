// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class FollowUpKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// "And who owns it?": the control under the question reads it after the question before, search finds what the two are about,
/// the time of the earlier one carries over, and nothing is kept once Ask is cleared.
@Suite("Ask: the control of a question that follows up")
@MainActor
struct AskFollowUpModelTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aFollowUpIsReadAfterTheQuestionBeforeUntilTurnedOff() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ask-follow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: FollowUpKey())
        let start = Date() - 2 * 86_400
        let id = try await store.startMeeting(at: start)
        try await store.append(Segment(channel: .others, start: 1, end: 4, text: "The launch budget was approved by the board", isFinal: true), to: id)
        try await store.append(Segment(channel: .others, start: 5, end: 9, text: "Lucía will present the roadmap", isFinal: true), to: id)
        try await store.endMeeting(id, at: start + 600)

        let ask = AskModel(store: store)
        ask.question = "What did we decide about the launch budget?"
        #expect(ask.offeredFollowUp == nil, "nothing before the first question")
        ask.ask()
        try await until { !ask.busy }
        #expect(ask.needsModel && !ask.passages.isEmpty)

        // A question that goes on: read after the first, so search finds the budget passage it is about.
        ask.question = "And who owns it?"
        #expect(ask.offeredFollowUp?.last == "What did we decide about the launch budget?" && ask.usesFollowUp)
        ask.ask()
        try await until { !ask.busy }
        #expect(ask.answeredReading == "What did we decide about the launch budget? And who owns it?")
        #expect(ask.passages.contains { $0.segments.contains { $0.text.contains("launch budget") } })
        #expect(ask.markedWords == ask.answeredReading, "the earlier question's words are marked too")
        // On screen, the control is still the one it was asked with.
        #expect(ask.offeredFollowUp?.last == "What did we decide about the launch budget?" && ask.usesFollowUp)

        // Turned off, the question is asked again on its own.
        ask.chooseFollowUp(false)
        try await until { !ask.busy }
        #expect(!ask.usesFollowUp && ask.answeredReading == "And who owns it?")

        // A question of its own is offered the control, off.
        ask.question = "Who will present the roadmap to the leadership team next quarter?"
        #expect(ask.offeredFollowUp?.last == "And who owns it?" && !ask.usesFollowUp)
        ask.chooseFollowUp(true)
        #expect(ask.usesFollowUp, "the person can turn it on")

        ask.clear()
        #expect(ask.offeredFollowUp == nil && ask.followUp == nil && ask.answeredFollowUp == nil, "nothing kept")
        ask.question = "And who owns it?"
        #expect(ask.offeredFollowUp == nil && !ask.usesFollowUp)
    }

    @Test func theTimeOfTheQuestionBeforeCarriesOver() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ask-follow-time-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: FollowUpKey())
        let ask = AskModel(store: store)
        ask.question = "What did we decide yesterday about the launch?"
        let named = try #require(ask.timeScope)
        ask.ask()
        try await until { !ask.busy }
        ask.question = "And who owns it?"
        #expect(ask.usesFollowUp && ask.timeScope?.interval == named.interval, "yesterday, from the question before")
        ask.chooseFollowUp(false)
        #expect(ask.timeScope == nil, "on its own the question names no time")
        ask.question = "And what did we say last week?"
        ask.chooseFollowUp(true)
        #expect(ask.timeScope != nil && ask.timeScope?.interval != named.interval, "a time of its own wins")
    }
}
