// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class WeekKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// This Week in Tasks mode: one week back or forward at a time, never past the current one.
@Suite("Tasks: This Week")
@MainActor
struct WeekDigestModelTests {
    @Test func theWeekMovesBackAndForwardButNeverPastThisWeek() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-week-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = MeetingsModel(store: try MeetingStore(directory: dir, keyStore: WeekKey()))
        #expect(model.tasksPane == .open && model.showsThisWeek)
        model.moveWeek(by: 1)
        #expect(model.showsThisWeek, "the weeks to come hold nothing yet")
        model.moveWeek(by: -1)
        #expect(!model.showsThisWeek)
        model.showThisWeek()
        #expect(model.showsThisWeek)
        await model.loadWeek()
        #expect(model.weekDigest?.isEmpty == true)
    }
}
