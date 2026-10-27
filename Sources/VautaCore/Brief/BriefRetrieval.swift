// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A passage of another meeting that goes with the brief's topic.
public struct BriefMeetingHit: Sendable, Equatable {
    public let meetingID: Int64
    public let title: String
    public let date: Date
    /// The text of the matching passage (the keyword gate reads it; the brief shows a clipped line).
    public let text: String
    public let segmentID: Int64?
    public let t: Double?
    /// The cosine of the topic to this passage alone, without keyword or name boosts (nil unless the search model ranked it).
    public let cosine: Double?

    public init(meetingID: Int64, title: String, date: Date, text: String, segmentID: Int64? = nil, t: Double? = nil, cosine: Double? = nil) {
        self.meetingID = meetingID
        self.title = title
        self.date = date
        self.text = text
        self.segmentID = segmentID
        self.t = t
        self.cosine = cosine
    }
}

public struct BriefDocumentHit: Sendable, Equatable {
    public let sourceID: Int64
    public let relPath: String
    public let fileName: String
    public let passageKey: String
    public let text: String
    public let cosine: Double?

    public init(sourceID: Int64, relPath: String, fileName: String, passageKey: String, text: String, cosine: Double? = nil) {
        self.sourceID = sourceID
        self.relPath = relPath
        self.fileName = fileName
        self.passageKey = passageKey
        self.text = text
        self.cosine = cosine
    }
}

/// What the brief asks the retrieval layer. The app's implementation uses the search model (never a remote embedding model: topics
/// are not sent to a server to be embedded) and the keyword index; tests and the evaluation use fakes.
public protocol BriefRetriever: Sendable {
    /// `.semantic` only when the search model is installed, its vectors cover the library and nothing keeps it idle.
    func mode() async -> BriefRankingMode
    /// Other meetings that go with `query`, best first (semantic: by cosine; keyword: BM25 candidates, unfiltered). With `mode` `.keyword`
    /// nothing is embedded: the caller chooses it while recording, in Low Power Mode and when the Mac is hot.
    func meetings(for query: String, excluding: Set<Int64>, limit: Int, mode: BriefRankingMode) async -> [BriefMeetingHit]
    /// Passages of the person's documents (and of the Notes export folders) that go with `query`, best first.
    func documents(for query: String, limit: Int, mode: BriefRankingMode) async -> [BriefDocumentHit]
    /// The raw cosine of each text to `query`, in order; nil when semantic ranking is not available.
    func cosines(query: String, texts: [String]) async -> [Double]?
}

/// The keyword fallback's gate: an item is kept only with at least two distinct content words in common with the topic, or one code
/// or rare name (the W10 S4 gate). It is a lexical test, never a cosine.
public enum BriefKeywordGate {
    public static let minimumSharedWords = 2

    public static func passes(query: String, text: String, locale: String?) -> Bool {
        let language = locale ?? Locale.current.identifier
        if QuestionDedup.keys(query, locale: language).intersection(QuestionDedup.keys(text, locale: language)).count >= minimumSharedWords { return true }
        let haystack = TextKeys.norm(text)
        for code in SemanticRanker.codes(in: query) where PromptText.containsNormalizedWords(haystack, TextKeys.norm(code)) { return true }
        return names(in: query, locale: language).contains { PromptText.containsNormalizedWords(haystack, $0) }
    }

    /// Capitalised words in the middle of a sentence (not the first word, not a stopword or a day or month): names of people,
    /// projects and clients, folded for comparison. Scripts without capitals give none (their names count as content words).
    static func names(in text: String, locale: String) -> [String] {
        let profile = LanguageProfile(identifier: locale)
        guard profile.capitalizationMarksNames else { return [] }
        var out: [String] = []
        var sentenceStart = true
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            // "Ana’s" names Ana.
            let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
            let bare = trimmed.split(whereSeparator: { "'’".contains($0) }).first.map(String.init) ?? trimmed
            defer { sentenceStart = word.last.map { profile.isSentenceTerminator($0) } ?? false }
            guard !sentenceStart, bare.count >= 3, let first = bare.first, first.isUppercase, !bare.contains(where: \.isNumber) else { continue }
            let norm = TextKeys.norm(bare)
            if profile.stopwords.contains(norm) || profile.noiseWords.contains(norm) || norm.isEmpty { continue }
            out.append(norm)
        }
        return out
    }
}

/// The topic text of a brief: the event's title, the last meeting's topics and decisions, the invitation's agenda lines.
public enum BriefQuery {
    public static let maximumCharacters = 400
    public static let minimumContentWords = 3

    public static func text(event: BriefEvent, facts: BriefFacts, invitationLines: [String]) -> String {
        var parts: [String] = [event.title]
        if let last = facts.last {
            parts += last.topics
            parts += last.decisions.map(\.text)
        }
        parts += invitationLines
        let joined = parts.map { SingleLineText.flatten(TextSanitizer.clean($0)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: ". ")
        return String(joined.prefix(maximumCharacters))
    }

    /// A generic title alone is too weak: with fewer than three content words the related sections are skipped.
    public static func isSufficient(_ query: String, locale: String?) -> Bool {
        QuestionDedup.keys(query, locale: locale ?? Locale.current.identifier).count >= minimumContentWords
    }
}

enum BriefNames {
    /// An attendee's full name, or the given name when it is the only one among the attendees, appears in `title` as whole words.
    static func attendeeIsNamed(in title: String, attendees: [String]) -> Bool {
        let norm = TextKeys.norm(title)
        guard !norm.isEmpty else { return false }
        let fullNames = attendees.map { TextKeys.norm($0) }.filter { $0.count >= 2 }
        if fullNames.contains(where: { PromptText.containsNormalizedWords(norm, $0) }) { return true }
        let givens = attendees.compactMap { MeetingStore.givenName(of: $0) }.map { TextKeys.norm($0) }.filter { $0.count >= 3 }
        let unique = givens.filter { given in givens.filter { $0 == given }.count == 1 }
        return unique.contains { PromptText.containsNormalizedWords(norm, $0) }
    }
}
