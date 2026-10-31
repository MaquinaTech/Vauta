// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class StretchKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// A stretch of transcript lines in the Meetings window: highlighted with ⇧-click or ⇧↑ ⇧↓ from the highlighted line, and deleted
/// together after one confirmation.
@Suite("Meetings: a highlighted stretch of transcript lines")
@MainActor
struct TranscriptStretchTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// A model showing the transcript of an ended meeting, or of the meeting being recorded.
    private func model(_ texts: [String], recording: Bool = false) async throws -> (MeetingsModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-stretch-\(UUID().uuidString)", isDirectory: true)
        let store = try MeetingStore(directory: dir, keyStore: StretchKey())
        let start = Date() - 86_400
        let id = try await store.startMeeting(at: recording ? .now : start, locale: Locale(identifier: "en-US"))
        for (i, text) in texts.enumerated() {
            try await store.append(Segment(channel: .others, start: Double(i * 5), end: Double(i * 5 + 4), text: text, isFinal: true), to: id)
        }
        if !recording { _ = try await store.endMeeting(id, at: start + 600) }
        let model = MeetingsModel(store: store)
        await model.reload()
        if recording { model.activeMeetingID = id }
        model.selectedID = id
        try await until { model.transcript.count == texts.count }
        model.tab = .transcript
        return (model, dir)
    }

    @Test func shiftClickHighlightsAStretchAndAClickEndsIt() async throws {
        let (model, dir) = try await model(["One", "Two", "Three", "Four"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = model.transcript.map(\.id)
        model.extendHighlight(to: model.transcript[2])
        #expect(model.highlightedStretch.map(\.id) == [t[2]], "with no line highlighted, ⇧-click highlights the line")
        model.extendHighlight(to: model.transcript[0])
        #expect(model.highlightedStretch.map(\.id) == [t[0], t[1], t[2]], "from the highlighted line, upwards too")
        #expect(!model.canCorrectHighlight && !model.canOpenSpeakerOptionsOfHighlight, "a stretch isn't one line to correct")
        model.highlight(model.transcript[1])
        #expect(model.highlighted == t[1] && model.highlightedStretch.map(\.id) == [t[1]], "a click in a stretch highlights that line alone")
        #expect(model.canCorrectHighlight)
        model.extendHighlight(to: model.transcript[3])
        model.extendHighlight(to: model.transcript[1])
        #expect(model.highlightExtent == nil, "back to the highlighted line, the stretch is that line")
        model.extendHighlight(to: model.transcript[3])
        // A search result, a mention or a mark highlights another line: the stretch ends.
        model.highlighted = t[0]
        #expect(model.highlightExtent == nil && model.highlightedStretch.map(\.id) == [t[0]])
    }

    @Test func shiftArrowsMoveTheEndOfTheStretch() async throws {
        let (model, dir) = try await model(["One", "Two", "Three", "Four"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = model.transcript.map(\.id)
        model.extendHighlight(by: 1)
        #expect(model.highlighted == t[0] && model.highlightExtent == nil, "with no line highlighted, ⇧↓ highlights the first")
        model.moveHighlight(by: 1)
        model.extendHighlight(by: 1)
        #expect(model.highlightedStretch.map(\.id) == [t[1], t[2]])
        model.extendHighlight(by: -2)
        #expect(model.highlightedStretch.map(\.id) == [t[0], t[1]], "past the highlighted line, the stretch turns upwards")
        model.extendHighlight(by: -1)
        #expect(model.highlightedStretch.map(\.id) == [t[0], t[1]], "it stops at the first line")
        model.moveHighlight(by: 1)
        #expect(model.highlighted == t[1] && model.highlightExtent == nil, "↓ alone ends the stretch, going on from its moving end")
    }

    @Test func aStretchIsDeletedTogetherAfterOneConfirmation() async throws {
        let (model, dir) = try await model(["One", "Two", "Three", "Four"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = model.transcript
        model.highlight(t[1])
        model.extendHighlight(to: t[2])
        model.confirmDeleteHighlight()
        let pending = try #require(model.pendingDeletion)
        guard case .lines(let lines) = pending else {
            Issue.record("not a stretch")
            return
        }
        #expect(lines.map(\.id) == [t[1].id, t[2].id] && model.transcript.count == 4, "nothing goes before the person confirms")
        #expect(pending.title.contains("2") && pending.confirmLabel == DeleteLineLabel.plural)
        #expect(pending.message.hasPrefix(ElapsedTime.stamp(t[1].start) + " – " + ElapsedTime.stamp(t[2].start) + "\n\n"))

        await model.performDeletion(pending)
        #expect(model.transcript.map(\.text) == ["One", "Four"])
        #expect(model.highlighted == nil && model.highlightExtent == nil)
        #expect(model.notice?.text == MeetingsModel.deletedNotice(lines: 2, marked: false))
        #expect(MeetingsModel.deletedNotice(lines: 1, marked: false) != MeetingsModel.deletedNotice(lines: 2, marked: false))
    }

    @Test func oneHighlightedLineIsStillOneLine() async throws {
        let (model, dir) = try await model(["One", "Two"])
        defer { try? FileManager.default.removeItem(at: dir) }
        model.highlight(model.transcript[1])
        model.confirmDeleteHighlight()
        guard case .line(let line) = try #require(model.pendingDeletion) else {
            Issue.record("not one line")
            return
        }
        #expect(line.id == model.transcript[1].id)
    }

    @Test func theMeetingBeingRecordedKeepsItsLines() async throws {
        let (model, dir) = try await model(["Live one", "Live two"], recording: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        model.highlight(model.transcript[0])
        model.extendHighlight(to: model.transcript[1])
        model.confirmDeleteHighlight()
        #expect(model.pendingDeletion == nil)
    }
}
