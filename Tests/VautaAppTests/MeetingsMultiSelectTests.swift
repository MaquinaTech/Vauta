// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class MultiSelectKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// Several meetings chosen in the Meetings list: no meeting is shown, and they can be deleted together.
@Suite("Meetings: choosing several meetings")
@MainActor
struct MeetingsMultiSelectTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func meeting(_ store: MeetingStore, ended: Bool = true) async throws -> Int64 {
        let start = Date() - 86_400
        let id = try await store.startMeeting(at: start, locale: Locale(identifier: "en-US"))
        try await store.append(Segment(channel: .others, start: 0, end: 4, text: "A line", isFinal: true), to: id)
        if ended { _ = try await store.endMeeting(id, at: start + 600) }
        return id
    }

    private func model(meetings count: Int) async throws -> (MeetingsModel, [Int64], URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-multi-\(UUID().uuidString)", isDirectory: true)
        let store = try MeetingStore(directory: dir, keyStore: MultiSelectKey())
        var ids: [Int64] = []
        for _ in 0..<count { ids.append(try await meeting(store)) }
        let model = MeetingsModel(store: store)
        await model.reload()
        return (model, ids, dir)
    }

    @Test func severalChosenShowNoMeetingAndOneShowsIt() async throws {
        let (model, ids, dir) = try await model(meetings: 3)
        defer { try? FileManager.default.removeItem(at: dir) }
        model.selection = [ids[0]]
        #expect(model.selectedID == ids[0])
        model.selection = [ids[0], ids[1]]
        #expect(model.selectedID == nil && model.choosesSeveral)
        #expect(model.chosenMeetings.map(\.id).sorted() == [ids[0], ids[1]].sorted())
        model.selection = [ids[1]]
        #expect(model.selectedID == ids[1] && !model.choosesSeveral)
    }

    @Test func aMeetingOpenedAnotherWayIsTheWholeSelection() async throws {
        let (model, ids, dir) = try await model(meetings: 3)
        defer { try? FileManager.default.removeItem(at: dir) }
        model.selection = [ids[0], ids[1]]
        model.selectedID = ids[2]
        #expect(model.selection == [ids[2]])
        model.selection = [ids[0], ids[1]]
        // Choosing nothing (Upcoming, a restore, a lock) clears the list too.
        model.selectedID = nil
        #expect(model.selection.isEmpty)
    }

    @Test func aFilterThatHidesChosenMeetingsTakesThemOut() async throws {
        let (model, ids, dir) = try await model(meetings: 3)
        defer { try? FileManager.default.removeItem(at: dir) }
        model.selection = Set(ids)
        model.filteredIDs = [ids[0], ids[1]]
        #expect(model.selection == [ids[0], ids[1]], "a hidden meeting is never deleted with the rest")
        model.filteredIDs = [ids[1]]
        #expect(model.selection == [ids[1]] && model.selectedID == ids[1], "the one left is shown")
    }

    @Test func inAskAClickMovesToTheMeetingItAdds() async throws {
        let (model, ids, dir) = try await model(meetings: 3)
        defer { try? FileManager.default.removeItem(at: dir) }
        model.selection = [ids[0]]
        model.mode = .ask
        #expect(model.listSelection(for: [ids[0], ids[1]]) == [ids[1]])
        model.mode = .meetings
        #expect(model.listSelection(for: [ids[0], ids[1]]) == [ids[0], ids[1]])
    }

    @Test func theChosenMeetingsAreDeletedTogether() async throws {
        let (model, ids, dir) = try await model(meetings: 3)
        defer { try? FileManager.default.removeItem(at: dir) }
        model.selection = [ids[0], ids[2]]
        #expect(model.canDeleteChosen)
        model.confirmDeleteChosen()
        try await until { model.pendingDeletion != nil }
        guard let deletion = model.pendingDeletion, case .meetings(let list, let keepsCreated) = deletion else {
            Issue.record("no confirmation")
            return
        }
        #expect(list.map(\.id).sorted() == [ids[0], ids[2]].sorted() && !keepsCreated)
        #expect(deletion.title.contains("2"))
        await model.performDeletion(deletion)
        #expect(model.meetings.map(\.id) == [ids[1]], "the meeting not chosen stays")
        #expect(model.selection.isEmpty && model.selectedID == nil)
    }

    @Test func aMeetingBeingRecordedKeepsTheChosenFromBeingDeleted() async throws {
        let (model, ids, dir) = try await model(meetings: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let open = try await meeting(model.store, ended: false)
        await model.reload()
        model.selection = [ids[0], open]
        #expect(model.choosesSeveral && !model.canDeleteChosen)
        model.confirmDeleteChosen()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.pendingDeletion == nil)
    }
}
