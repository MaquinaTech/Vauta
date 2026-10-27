// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where Ask looks.
public enum KnowledgeScope: String, Sendable, CaseIterable {
    case everywhere, meetings, documents
}

/// Chooses which meeting passages and which document passages go to the model, within one budget.
///
/// The two ranked lists are interleaved by their RRF score. With both kinds present, neither may take more than two thirds of
/// the slots (rounded up), so one never drowns the other; documents never take more than `documentLimit`; and the passages
/// share the character budget (a passage that does not fit is skipped, a smaller one after it may still).
public enum KnowledgeMixer {
    public struct Candidate: Sendable, Equatable {
        public var score: Double
        public var characters: Int
        public init(score: Double, characters: Int) {
            self.score = score
            self.characters = characters
        }
    }

    public struct Choice: Sendable, Equatable {
        public var meetings: [Int] = []
        public var documents: [Int] = []
    }

    /// Scores that depend only on the position in a ranked list (reciprocal rank, as RRF), for mixing lists whose own scores are on
    /// different scales (cosine against keyword fusion).
    public static func rankScores(count: Int) -> [Double] {
        (0..<max(0, count)).map { 1 / (60 + Double($0)) }
    }

    /// Indexes into `meetings` and `documents`, each in their own rank order.
    public static func mix(meetings: [Candidate], documents: [Candidate], limit: Int, documentLimit: Int, maxCharacters: Int) -> Choice {
        var choice = Choice()
        guard limit > 0 else { return choice }
        let both = !meetings.isEmpty && !documents.isEmpty
        let sideCap = both ? (limit * 2 + 2) / 3 : limit
        let documentCap = min(documentLimit, sideCap)
        let meetingCap = sideCap
        enum Side { case meeting, document }
        var all: [(side: Side, index: Int, score: Double, characters: Int)] = []
        for (i, c) in meetings.enumerated() { all.append((.meeting, i, c.score, c.characters)) }
        for (i, c) in documents.enumerated() { all.append((.document, i, c.score, c.characters)) }
        // Higher score first; on a tie the meeting passage, and within a side the order it came in.
        all.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.side != b.side { return a.side == .meeting }
            return a.index < b.index
        }
        var used = 0
        for item in all {
            if choice.meetings.count + choice.documents.count >= limit { break }
            switch item.side {
            case .meeting: if choice.meetings.count >= meetingCap { continue }
            case .document: if choice.documents.count >= documentCap { continue }
            }
            guard used + item.characters <= maxCharacters else { continue }
            used += item.characters
            if item.side == .meeting { choice.meetings.append(item.index) } else { choice.documents.append(item.index) }
        }
        choice.meetings.sort()
        choice.documents.sort()
        return choice
    }
}
