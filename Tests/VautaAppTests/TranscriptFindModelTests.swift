// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class FindKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// Find in Meeting (⌘F, ⌘G, ⇧⌘G): the places in the transcript of the meeting shown, the one chosen highlighted, one speaker's only.
@Suite("Meetings: Find in Meeting")
@MainActor
struct TranscriptFindModelTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func findMovesThroughThePlacesAndClosesWithTheTranscript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-find-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: FindKey())
        let start = Date() - 86_400
        let id = try await store.startMeeting(at: start)
        for (i, text) in ["The budget is set", "Nothing about it here", "Budget again, and the budget twice", "The end"].enumerated() {
            try await store.append(Segment(channel: .others, start: Double(i * 5), end: Double(i * 5 + 4), text: text, isFinal: true), to: id)
        }
        try await store.endMeeting(id, at: start + 600)

        let model = MeetingsModel(store: store)
        await model.reload()
        #expect(!model.canFindInMeeting)
        model.showFind()
        #expect(!model.findShown && model.searchFocusRequest == 1, "with no meeting shown, ⌘F searches the meetings")

        model.selectedID = id
        try await until { model.transcript.count == 4 }
        let lines = model.transcript.map(\.id)
        #expect(model.canFindInMeeting && model.tab == .summary)
        model.showFind()
        #expect(model.findShown && model.tab == .transcript && model.findFocusRequest == 1)

        model.findText = "BUDGET"
        #expect(model.findMatches.map(\.segment) == [lines[0], lines[2], lines[2]], "case ignored, every place in a line")
        #expect(model.findIndex == 0 && model.highlighted == lines[0] && model.findCount == "1 of 3")
        model.findNext()
        #expect(model.findIndex == 1 && model.highlighted == lines[2])
        model.findNext()
        let marks = model.findRanges(of: lines[2])
        #expect(model.findIndex == 2 && marks.all.count == 2 && marks.current == marks.all.last, "the second place of the line is the chosen one")
        #expect(model.findRanges(of: lines[1]).all.isEmpty)
        model.findNext()
        #expect(model.findIndex == 0 && model.highlighted == lines[0], "after the last, the first")
        model.findNext(forward: false)
        #expect(model.findIndex == 2 && model.findCount == "3 of 3", "before the first, the last")
        model.findText = "zzz"
        #expect(model.findMatches.isEmpty && model.findCount == "No Results" && !model.canFindNext)

        // One speaker's lines only.
        model.findText = "budget"
        model.transcript = model.transcript.map { line in
            MeetingStore.StoredSegment(id: line.id, meetingID: line.meetingID, channel: line.channel, start: line.start, end: line.end, text: line.text,
                                       speaker: SpeakerTag(id: line.id == lines[0] ? 7 : 8, ordinal: line.id == lines[0] ? 1 : 2))
        }
        model.findSpeaker = 8
        #expect(model.findMatches.map(\.segment) == [lines[2], lines[2]] && model.highlighted == lines[2])
        model.findSpeaker = nil
        #expect(model.findMatches.count == 3)

        // The bar is the transcript's: another tab closes it, and ⌘G opens it again on the same text.
        model.findSpeaker = 8
        model.tab = .summary
        #expect(!model.findShown && model.findSpeaker == nil && model.findMatches.isEmpty && model.findText == "budget")
        #expect(model.canFindNext)
        model.highlighted = nil
        model.findNext()
        #expect(model.findShown && model.tab == .transcript && model.findMatches.count == 3 && model.highlighted == lines[0])
        #expect(model.findRanges(of: lines[0]).current != nil)

        model.closeFind()
        #expect(model.findRanges(of: lines[0]).all.isEmpty, "no marks once the bar is closed")
    }
}
