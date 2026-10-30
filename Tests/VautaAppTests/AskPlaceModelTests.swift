// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class PlaceKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// "The last meeting": the control under the question finds it, Ask looks only in it, and turning the control off looks in all.
@Suite("Ask: the control of the meetings a question names by their place")
@MainActor
struct AskPlaceModelTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func theLastMeetingIsTheOneSearchedUntilTheControlIsTurnedOff() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ask-place-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: PlaceKey())
        func meeting(_ text: String, daysAgo: Double) async throws -> Int64 {
            let start = Date() - daysAgo * 86_400
            let id = try await store.startMeeting(at: start)
            try await store.append(Segment(channel: .others, start: 1, end: 4, text: text, isFinal: true), to: id)
            try await store.endMeeting(id, at: start + 600)
            return id
        }
        let older = try await meeting("The launch budget was approved by the board", daysAgo: 3)
        let latest = try await meeting("The launch budget was cut in half", daysAgo: 1)

        let ask = AskModel(store: store)
        ask.question = "What did we say about the launch budget in the last meeting?"
        #expect(ask.place == AskMeetingPlace(which: .last(1), ofNamed: false), "read as English")
        try await until { ask.offeredPlace != nil }
        #expect(ask.offeredPlace?.map(\.id) == [latest] && ask.usesPlace)

        // Without a model, the passages that match are all there is: only the last meeting's.
        ask.ask()
        try await until { !ask.busy }
        #expect(ask.needsModel && !ask.passages.isEmpty && ask.passages.allSatisfy { $0.meeting.id == latest })

        ask.choosePlace(false)
        try await until { !ask.busy }
        #expect(!ask.usesPlace && Set(ask.passages.map(\.meeting.id)) == [older, latest], "asked again over all meetings")
    }
}
