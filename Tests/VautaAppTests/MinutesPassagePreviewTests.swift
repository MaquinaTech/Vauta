// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class PreviewKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// The preview of a time in the minutes shows the line that opening that moment highlights.
@Suite("Meetings: the preview of a time in the minutes")
@MainActor
struct MinutesPassagePreviewTests {
    @Test func aTimePreviewsTheLineItOpens() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-minutes-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: PreviewKey())
        let start = Date() - 3_600
        let id = try await store.startMeeting(at: start)
        for (i, text) in ["We open the review", "The budget is approved", "Ana sends the deck"].enumerated() {
            try await store.append(Segment(channel: .others, start: Double(i * 10), end: Double(i * 10 + 8), text: text, isFinal: true), to: id)
        }
        try await store.endMeeting(id, at: start + 600)
        let model = MeetingsModel(store: store)
        await model.reload()
        model.selectedID = id
        for _ in 0..<250 where model.transcript.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.passage(at: 12)?.text == "The budget is approved")
        #expect(model.passage(at: 9.6)?.text == "The budget is approved", "half a second early, as opening the moment does")
        #expect(model.passage(at: 400)?.text == "Ana sends the deck")
        let segs = try await store.segments(of: id, echoes: true)
        #expect(model.passage(at: 12)?.id == segs.last { $0.start <= 12.5 }?.id, "the same rule as open(meeting:at:)")
    }
}
