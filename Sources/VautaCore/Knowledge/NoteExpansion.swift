// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What the model wrote from one of the user's shorthand notes. It lives in its own row: the user's words
/// (`MeetingNote.text`) are never touched by any model code. Every sentence cites transcript segments and was
/// verified like the minutes (`NoteExpansionVerifier`).
public struct NoteExpansion: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        /// Not written yet (a failed attempt waits for the next try).
        case pending
        case done
        /// The model found nothing in the transcript about the note.
        case notFound = "not_found"
        case failed
        /// The user removed it.
        case dismissed
    }

    /// Which pass wrote it.
    public enum Pass: String, Sendable, Equatable {
        /// While recording, with the fast model; provisional.
        case live
        /// When the meeting ended, with the main model, before the minutes.
        case closing = "final"
        /// The user asked for it (a note added or edited after the meeting, or "Expand Again").
        case manual
    }

    public struct Cite: Sendable, Codable, Equatable, Hashable {
        public var seg: Int64
        public var t: Double
        public init(seg: Int64, t: Double) { self.seg = seg; self.t = t }
    }

    /// One verified sentence. The stored JSON keys never change meaning.
    public struct Sentence: Sendable, Codable, Equatable {
        public var text: String
        public var cites: [Cite]
        /// The verbatim quote that backs the sentence (kept so a split of the segment moves the citation exactly).
        public var quote: String
        /// Figures, dates or names are not in the cited segments (`MinutesVerifier`).
        public var unconfirmed: Bool
        /// The transcript says something different from the note: shown as "The transcript says: …".
        public var differs: Bool

        public init(text: String, cites: [Cite] = [], quote: String = "", unconfirmed: Bool = false, differs: Bool = false) {
            self.text = text; self.cites = cites; self.quote = quote; self.unconfirmed = unconfirmed; self.differs = differs
        }

        private enum CodingKeys: String, CodingKey { case text, cites, quote, unconfirmed, differs }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            cites = try c.decodeIfPresent([Cite].self, forKey: .cites) ?? []
            quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
            unconfirmed = try c.decodeIfPresent(Bool.self, forKey: .unconfirmed) ?? false
            differs = try c.decodeIfPresent(Bool.self, forKey: .differs) ?? false
        }
    }

    public let noteID: Int64
    public let meetingID: Int64
    public var state: State
    public var pass: Pass
    public var sentences: [Sentence]
    /// The sentences joined (what search and export read).
    public var plain: String
    /// `TextKeys.norm` of the note text when it was expanded: if it differs from the note now, the expansion is stale.
    public var sourceKey: String
    /// The last segment the model could see.
    public var uptoSegment: Int64
    /// The user rewrote the expansion: no pass replaces it any more.
    public var userEdited: Bool
    /// The version before the last change, for one level of Undo.
    public var previous: Previous?
    /// `JobErrorCode` raw value of the last failure.
    public var errorCode: String?
    public var updatedAt: Date

    public struct Previous: Sendable, Codable, Equatable {
        public var state: String
        public var sentences: [Sentence]
        public var userEdited: Bool
        /// The note text this version was written from; nil in versions saved before it was kept.
        public var sourceKey: String?

        public init(state: String, sentences: [Sentence], userEdited: Bool, sourceKey: String?) {
            self.state = state; self.sentences = sentences; self.userEdited = userEdited; self.sourceKey = sourceKey
        }

        private enum CodingKeys: String, CodingKey { case state, sentences, userEdited = "user_edited", sourceKey = "source_key" }
    }

    public init(noteID: Int64, meetingID: Int64, state: State, pass: Pass, sentences: [Sentence] = [], plain: String? = nil, sourceKey: String,
                uptoSegment: Int64 = 0, userEdited: Bool = false, previous: Previous? = nil, errorCode: String? = nil,
                updatedAt: Date = .now) {
        self.noteID = noteID; self.meetingID = meetingID; self.state = state; self.pass = pass; self.sentences = sentences
        self.plain = plain ?? sentences.map(\.text).joined(separator: " "); self.sourceKey = sourceKey; self.uptoSegment = uptoSegment
        self.userEdited = userEdited; self.previous = previous; self.errorCode = errorCode; self.updatedAt = updatedAt
    }

    public var hasText: Bool { !sentences.isEmpty }
}

/// A note with its expansion, if any.
public struct NoteRow: Sendable, Identifiable, Equatable {
    public let note: MeetingNote
    public var expansion: NoteExpansion?
    public var id: Int64 { note.id }

    public init(note: MeetingNote, expansion: NoteExpansion?) { self.note = note; self.expansion = expansion }

    /// The note was changed after the expansion was written from it. Words the user wrote are never out of date: no pass
    /// replaces them, and every export, the minutes and the Notes tab keep them.
    public var isStale: Bool {
        guard let expansion, expansion.state == .done || expansion.state == .notFound, !expansion.userEdited else { return false }
        return expansion.sourceKey != TextKeys.norm(note.text)
    }

    /// The first thing the user sees under the note: nothing for dismissed, failed or missing expansions.
    public var visibleSentences: [NoteExpansion.Sentence] {
        guard let expansion, expansion.state == .done else { return [] }
        return expansion.sentences
    }
}

/// The text of an expansion as the user edits it: one sentence per line.
public enum NoteExpansionText {
    public static func joined(_ sentences: [NoteExpansion.Sentence]) -> String { sentences.map(\.text).joined(separator: "\n") }
}
