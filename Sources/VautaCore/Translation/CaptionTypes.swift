// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// One caption: what was said and its translation.
public struct CaptionLine: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// Still being spoken: the text may change.
        case partial
        /// Finished speaking; the final translation is on its way (the last
        /// provisional translation stays on screen meanwhile).
        case translating
        /// Final text, final translation.
        case final
    }

    /// Stable while the line goes from partial to final, so the view updates it in place.
    public let id: Int
    public var original: String
    public var translation: String
    public var state: State
    /// The translation comes from the user's model server (it replaced Apple's).
    public var isRefined: Bool
    /// Which of the other participants said it, as the number the speaker has while recording (Speaker 2 is 2).
    /// nil while the line is still being spoken, and when speakers are not separated.
    public var speaker: Int?

    public init(id: Int, original: String, translation: String, state: State, isRefined: Bool = false, speaker: Int? = nil) {
        self.id = id
        self.original = original
        self.translation = translation
        self.state = state
        self.isRefined = isRefined
        self.speaker = speaker
    }
}

/// What the captions panel should say when there is nothing to caption.
public enum CaptionStatus: Sendable, Equatable {
    /// The translator is being prepared.
    case starting
    /// Ready, waiting for someone to speak.
    case listening
    /// The language pair must be downloaded first.
    case needsDownload
    case downloading
    /// Apple's Translation does not offer this pair.
    case unsupported
    /// The meeting language and the target are the same.
    case sameLanguage
    case paused
    /// The translator stopped working.
    case failed
}

/// How the model server's refinement of finished sentences is going, for a
/// discreet indicator. Never an alert.
public enum RefinementStatus: Sendable, Equatable {
    /// Off, or no server to ask.
    case off
    /// On; no sentence has been improved or has failed yet.
    case active
    /// The latest sentence was improved by the server.
    case improved
    /// The latest attempt failed or was too slow: Apple's translation stays.
    case unavailable
}

/// Everything the captions panel draws, in one value.
public struct CaptionSnapshot: Sendable, Equatable {
    public var pair: TranslationPair?
    public var status: CaptionStatus
    /// Oldest first; the last may be a partial.
    public var lines: [CaptionLine]
    public var refinement: RefinementStatus

    public init(pair: TranslationPair? = nil, status: CaptionStatus = .starting, lines: [CaptionLine] = [],
                refinement: RefinementStatus = .off) {
        self.pair = pair
        self.status = status
        self.lines = lines
        self.refinement = refinement
    }
}

/// The final translation of one segment, to be stored.
public struct FinalTranslation: Sendable, Equatable {
    /// The key the caller gave the segment (`LiveTranslator.submit`).
    public let key: Int
    public let language: String
    public let text: String
    /// The text is the model server's version; it replaces what was stored from Apple's.
    public let isRefined: Bool
    /// The sentence that was translated, so a late answer can be checked against what was stored.
    public let source: String

    public init(key: Int, language: String, text: String, isRefined: Bool = false, source: String = "") {
        self.key = key
        self.language = language
        self.text = text
        self.isRefined = isRefined
        self.source = source
    }
}
