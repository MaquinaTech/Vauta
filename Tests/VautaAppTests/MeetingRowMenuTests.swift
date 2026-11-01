// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class RowMenuKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// The meetings list's context menu acts on the row it was opened on, never on the meeting shown before.
@Suite("Meetings: the list's context menu")
@MainActor
struct MeetingRowMenuTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func meeting(_ store: MeetingStore, lines: Int, ended: Bool = true) async throws -> Int64 {
        let start = Date() - 86_400
        let id = try await store.startMeeting(at: start, locale: Locale(identifier: "en-US"))
        for i in 0..<lines {
            try await store.append(Segment(channel: .others, start: Double(i * 5), end: Double(i * 5 + 4), text: "Line \(i)", isFinal: true), to: id)
        }
        if ended { _ = try await store.endMeeting(id, at: start + 600) }
        return id
    }

    @Test func deleteFromTheMenuAsksAboutTheRowsMeeting() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-row-menu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: RowMenuKey())
        let shown = try await meeting(store, lines: 1)
        let clicked = try await meeting(store, lines: 3)
        let model = MeetingsModel(store: store)
        await model.reload()
        model.selectedID = shown
        await model.loadDetail()
        #expect(model.transcript.count == 1)

        await model.perform(.delete, onMeeting: clicked)
        #expect(model.selectedID == clicked, "the row's meeting is selected, as a click would")
        // The confirmation counts what Vauta created for the meeting first.
        try await until { model.pendingDeletion != nil }
        guard case .meeting(let meeting, let segments, _, _, _)? = model.pendingDeletion else {
            Issue.record("no confirmation")
            return
        }
        #expect(meeting.id == clicked)
        #expect(segments == 3, "it counts the row's own transcript, not the one shown before")
    }

    @Test func aMeetingBeingRecordedCantBeDeletedFromTheMenu() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-row-menu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: RowMenuKey())
        let done = try await meeting(store, lines: 1)
        let open = try await meeting(store, lines: 1, ended: false)
        let model = MeetingsModel(store: store)
        await model.reload()
        #expect(model.canDeleteFromMenu(done))
        #expect(!model.canDeleteFromMenu(open))
    }
}
