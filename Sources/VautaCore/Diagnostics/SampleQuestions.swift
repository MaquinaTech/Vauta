// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// Invented material for the scenes of the live answers: an earlier meeting of the sample world, a line of it, and a question the
/// featured meeting leaves open. All of it is written in the language being rendered (the sample content mirrors the English one).
extension SampleContent {
    public struct PastMeetingSample: Sendable {
        public let title: String
        public let daysAgo: Int
        /// A line of that meeting that holds an answer, and its position in the meeting.
        public let line: String
        public let lineIndex: Int
    }

    /// The Northwind kickoff call, whose second line says what the customer is most interested in.
    public var pastMeetingSample: PastMeetingSample {
        let m = meetings[2]
        return PastMeetingSample(title: m.title, daysAgo: m.daysAgo, line: m.lines[1].text, lineIndex: 1)
    }

    /// A question the featured meeting leaves open and no source answers.
    public var unansweredQuestion: String { meetings[0].questions[0] }

    /// The featured meeting's lines, to quote.
    public var featuredLineTexts: [String] { meetings[0].lines.map(\.text) }
}

extension SampleWorld {
    /// The document the scenes of the live answers cite (a real source of the store while they run).
    public static let questionDocumentName = "Onboarding.pdf"

    /// Removes the questions the scenes of the live answers stored, so no other scene shows them.
    public func clearQuestions() async throws {
        for id in meetingIDs {
            for q in try await store.detectedQuestions(id) { try await store.removeDetectedQuestion(q.id) }
        }
        for source in try await store.documentSources() where source.displayName == Self.questionDocumentName { try await store.removeDocumentSource(source.id) }
    }
}
#endif
