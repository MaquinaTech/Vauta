// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class CitationKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// A citation of the minutes of an older meeting is named by its minutes, not by a moment, and opens them.
@Suite("Ask: a citation of an older meeting's minutes")
@MainActor
struct AskMinutesCitationTests {
    @Test func itIsNamedByTheMinutesAndOpensThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ask-minutes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ask = AskModel(store: try MeetingStore(directory: dir, keyStore: CitationKey()))
        ask.meetingTitle = { _ in "Weekly sync" }
        let line = MinutesEvidence.id(.decision, ref: 3)
        ask.segmentMeeting[line] = 7
        ask.segments[line] = CitableSegment(id: line, channel: .others, start: 754, text: "Remove the teletext button.")
        ask.segmentMeeting[42] = 7
        ask.segments[42] = CitableSegment(id: 42, channel: .others, start: 754, text: "Yeah, drop it.")
        #expect(ask.citationLabel(line) == "Weekly sync · Minutes")
        #expect(ask.citationLabels([42, line]).last == "Weekly sync · Minutes", "never shortened to a time, as a moment of the same meeting is")
        var minutes: Int64?, moment: (Int64, Int64)?
        ask.openMinutes = { minutes = $0 }
        ask.openCitation = { moment = ($0, $1) }
        ask.open(citation: line)
        #expect(minutes == 7 && moment == nil)
        ask.open(citation: 42)
        #expect(moment?.0 == 7 && moment?.1 == 42)
    }
}
