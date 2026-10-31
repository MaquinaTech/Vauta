// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta

/// "Update Now" in the Live notes card: the card offers it to the pointer, the keyboard and VoiceOver, and the recorder starts the notes
/// through `LiveNotesSchedule`, so a press never starts a second run. Read from the source: a recorder needs a recording to run.
@Suite("Live notes: Update Now")
struct LiveNotesUpdateNowTests {
    static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theCardOffersItWithALabelAndAClickArea() throws {
        let card = try Self.source("Sources/Vauta/App/Panel/LiveTools.swift")
        #expect(card.contains("model.updateLiveNotesNow()") && card.contains(".disabled(!model.canUpdateLiveNotesNow)"))
        #expect(card.contains(#".accessibilityLabel(Text("Update Now""#))
        #expect(card.contains(".frame(minWidth: 20, minHeight: 20)"), "a click area of at least 20 × 20 points")
        #expect(card.contains("if model.liveNotesRunning"), "while the notes are written the card shows it, with no button")
    }

    @Test func theRecorderAsksTheScheduleWithItsBusyRule() throws {
        let session = try Self.source("Sources/Vauta/App/RecorderModel+Session.swift")
        #expect(session.contains("LiveNotesSchedule.starts("))
        #expect(session.contains("busy: liveNotesTask != nil || noteExpansionTask != nil, asked: liveNotesAsked"))
        #expect(!session.contains("liveNotesInterval"), "one schedule, in VautaCore")
    }
}
