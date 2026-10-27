// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The bar for an expanded note is the one for the minutes and for Ask:
/// - a sentence cites only segments that were sent, and needs a verbatim quote (at least 8 normalized characters)
///   found in a cited segment, otherwise it is dropped; only the segments that hold the quote stay cited;
/// - the figures, dates and names of a sentence that its cited text does not back mark it "Unconfirmed"
///   (`MinutesVerifier`, the same functions and the same handling of every script).
public enum NoteExpansionVerifier {
    static let maxTextLength = 600

    static func verify(_ raw: [VautaPrompts.RawNoteExpansion.Sentence], check: VautaPrompts.NoteCheck) -> [NoteExpansion.Sentence] {
        var out: [NoteExpansion.Sentence] = []
        var seen = Set<String>()
        let others = check.people.filter { $0.kind == .person && $0.id != check.selfEntity }
        for sentence in raw {
            guard out.count < check.maxSentences else { break }
            guard let text = sentence.text.map({ PromptText.clip(check.tidy ? NoteReply.tidied($0) : $0, maxTextLength) }), !text.isEmpty,
                  !seen.contains(TextKeys.norm(text)) else { continue }
            var ids: [Int64] = []
            for id in sentence.seg where check.sent[id] != nil && !ids.contains(id) { ids.append(id) }
            let quote = TextKeys.norm(sentence.quote ?? "")
            // Only the cited segments that hold the quote back the sentence (as for the answers of Ask); the figures,
            // dates and names are checked against those alone, so an unrelated line cannot vouch for them.
            guard quote.count >= 8 else { continue }
            let backing = ids.compactMap { check.sent[$0] }.filter { TextKeys.norm($0.text).contains(quote) }
                .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            guard !backing.isEmpty else { continue }
            // Only a sentence that passed the checks counts as seen: a repeat with a good quote still gets its chance.
            seen.insert(TextKeys.norm(text))
            let joined = backing.map(\.text).joined(separator: " ")
            let speaker = backing.lazy.compactMap { check.directory.person(of: $0.speaker) }.first { $0.confident }?.entity
            let unconfirmed = !MinutesVerifier.figuresAreInSegment(item: text, segment: joined)
                || !MinutesVerifier.namedPeopleAreBacked(itemText: text, people: others, segment: joined, speakerEntity: speaker)
            out.append(NoteExpansion.Sentence(text: text, cites: backing.map { .init(seg: $0.id, t: $0.start) },
                                              quote: PromptText.clip(sentence.quote ?? "", 300), unconfirmed: unconfirmed,
                                              differs: sentence.differs))
        }
        return out
    }
}

/// When the live pass may expand a note (pure, so it is tested without a recording). A note waits until the speaker
/// has had time to finish the point being noted, and until there is enough transcript to expand it from.
public enum NoteExpansionPolicy {
    /// Characters of final transcript from `lookBack` seconds before the note to now.
    public static let minContextCharacters = 600
    /// The speaker's follow-up: seconds since the note, or characters said after it.
    public static let settleSeconds: Double = 45
    public static let settleCharacters = 900
    /// How far back the live window starts.
    public static let lookBack: Double = 150
    /// Failed live attempts before the note waits for the final pass.
    public static let maxLiveAttempts = 3

    public struct Pending: Sendable, Equatable {
        public var noteID: Int64
        /// Seconds from the start of the meeting when it was typed.
        public var t: Double
        public var attempts: Int
        public init(noteID: Int64, t: Double, attempts: Int = 0) { self.noteID = noteID; self.t = t; self.attempts = attempts }
    }

    /// The note to expand now, if any: the oldest that is ready. Nothing starts while another expansion is in flight.
    /// `transcript` is the final segments so far as `(start, characters)`; `now` is the current offset.
    public static func next(pending: [Pending], transcript: [(start: Double, characters: Int)], now: Double,
                            inFlight: Bool) -> Pending? {
        guard !inFlight else { return nil }
        return pending.sorted { ($0.t, $0.noteID) < ($1.t, $1.noteID) }.first { note in
            guard note.attempts < maxLiveAttempts else { return false }
            let since = transcript.filter { $0.start >= note.t - lookBack }.reduce(0) { $0 + $1.characters }
            guard since >= minContextCharacters else { return false }
            let after = transcript.filter { $0.start > note.t }.reduce(0) { $0 + $1.characters }
            return now - note.t >= settleSeconds || after >= settleCharacters
        }
    }

    /// Live notes wait while a note is ready (what the user typed comes first).
    public static func liveNotesShouldWait(pending: [Pending], transcript: [(start: Double, characters: Int)], now: Double) -> Bool {
        next(pending: pending, transcript: transcript, now: now, inFlight: false) != nil
    }
}
