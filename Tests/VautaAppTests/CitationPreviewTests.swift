// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta

/// The preview of a cited passage in Ask: every citation of an answer is a `CitationLink`, which offers it to the pointer (after a rest),
/// to the keyboard (Space) and to VoiceOver (a named action). Read from the source: SwiftUI's views cannot be inspected without a package.
@Suite("Ask: the preview of a cited passage")
struct CitationPreviewTests {
    static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theLinkOffersThePreviewToThePointerTheKeyboardAndVoiceOver() throws {
        let link = try Self.source("Sources/Vauta/App/Meetings/CitationLink.swift")
        #expect(link.contains(".onHover") && link.contains(".onKeyPress(.space)") && link.contains(".popover(isPresented: $previewing"))
        #expect(link.contains(".accessibilityActions {") && link.contains(#"Text("Preview Passage""#), "a named action, only on a link with a passage")
        #expect(link.contains(".passagePreview(label, passage: segment.map(PreviewedPassage.init)"), "a citation of Ask has the preview")
        #expect(link.contains("ProtectedText("), "copy protection holds in the preview")
        #expect(CitationLink.restDelay >= .milliseconds(400), "the preview does not open on the way to something else")
    }

    @Test func theTimesOfTheMinutesPreviewTheirLine() throws {
        let time = try Self.source("Sources/Vauta/App/Meetings/MeetingDetailView.swift")
        #expect(time.contains(".passagePreview(ElapsedTime.stamp(t), passage: passage, open: action)"))
        let minutes = try Self.source("Sources/Vauta/App/Meetings/SummaryTab.swift")
        #expect(minutes.components(separatedBy: "TimeButton(").count - 1 == 3, "decisions, marks and the lines with a cited moment")
        #expect(minutes.components(separatedBy: "passage:").count - 1 == 3, "each of them previews its line")
    }

    @Test func everyCitationOfAnAnswerIsALink() throws {
        let answer = try Self.source("Sources/Vauta/App/Meetings/AskView+Answer.swift")
        #expect(answer.components(separatedBy: "CitationLink(").count - 1 == 2, "the claims' citations and the moments of a not-yet answer")
        #expect(!answer.contains("Button(labels[index])"))
    }
}
