// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The recorder tells the model service that a segment was saved from a task of its own: the path of the transcript never waits for it.
@Suite("Recorder: the incremental reading never blocks the transcript")
struct RecorderWarmTriggerTests {
    static func session() throws -> String {
        let url = LanguageModelIntegrationTests.sources.appendingPathComponent("Vauta/App/RecorderModel+Session.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func theTriggerIsCalledOnTheSegmentPathButStartsATask() throws {
        let text = try Self.session()
        #expect(text.contains("considerWarmPrefix(liveID: liveID, segment: segment)"))
        guard let start = text.range(of: "private func considerWarmPrefix(") else { Issue.record("no considerWarmPrefix"); return }
        let body = String(text[start.lowerBound...].prefix(1_200))
        #expect(body.contains("Task {") && body.contains("await llm.segmentSaved("), "the call is inside a task of its own")
        // Nothing before the task awaits: the function is synchronous.
        let head = body.components(separatedBy: "Task {")[0]
        #expect(!head.contains("await ") && !head.contains("MainActor.run"), "no await on the segment path")
        // The function that handles a segment does not await the trigger.
        #expect(!text.contains("await considerWarmPrefix") && !text.contains("try await considerWarmPrefix"))
    }

    @Test func thePathThatSavesTheSegmentOnlyReadsItsRowAfterTheWriteIsDone() throws {
        let text = try Self.session()
        #expect(text.contains("await pending?.value") && text.contains("segmentRowIDs[liveID]"))
    }
}
