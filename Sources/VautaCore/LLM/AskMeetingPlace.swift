// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The meetings a question names by their place among the meetings ("what did we decide in the last meeting?", "la reunión anterior",
/// "the last three calls", "the first meeting with Ana", "前回の会議", "上次会议"), read without a model, so Ask can look only in them.
/// Which meetings those are is the store's (`MeetingStore.meetingIDs(at:entities:from:to:)`).
///
/// - Next to a point in time ("since the last meeting", "antes de la última reunión") it is not read: it names a time, not meetings to
///   look in.
/// - Said by whom it was with or what it was about ("the last meeting with Ana", "la última reunión sobre Kobaltix"), or by what was
///   said in it ("the last meeting where we discussed Kobaltix"), only the meetings that name the question's people or projects count
///   (`ofNamed`); when the question names none Vauta knows, it is not used.
public struct AskMeetingPlace: Sendable, Equatable {
    public enum Which: Sendable, Equatable {
        /// The latest n meetings.
        case last(Int)
        /// The first n meetings.
        case first(Int)
        /// The one before the latest.
        case beforeLast
    }

    public let which: Which
    /// Only the meetings that name the people or projects the question names.
    public let ofNamed: Bool

    public init(which: Which, ofNamed: Bool) {
        self.which = which
        self.ofNamed = ofNamed
    }

    /// The place `question` names, written in one of `languages` (as `AskTimeScope.read`), or nil when it names none, or two.
    public static func read(_ question: String, languages: [String]) -> AskMeetingPlace? {
        let codes = Set(languages.compactMap { Locale(identifier: $0).language.languageCode?.identifier })
        var found: [AskMeetingPlace?] = []
        // Clause by clause: normalized, the comma of "Las tres reuniones anteriores, ¿qué decidieron?" is gone, and its "qué" would
        // read as a clause about the meetings.
        for clause in question.split(whereSeparator: { ",;:¿?¡!，、；：？！".contains($0) }) {
            let text = TextKeys.norm(String(clause))
            guard !text.isEmpty else { continue }
            let tokens = text.split(separator: " ").map(String.init)
            for code in codes.sorted() {
                if let lexicon = AskPlaceWords.latin[code], let nouns = AskTimeWords.latin[code]?.meetings {
                    found += readLatin(tokens, lexicon, nouns: nouns)
                }
                if let script = AskPlaceWords.scripts[code] { found += readScript(text, script, korean: code == "ko") }
            }
        }
        // A point in time ("since the last meeting") or two places ("the first and the last meeting") are not one set of meetings.
        guard let first = found.first, let place = first, found.allSatisfy({ $0 == place }) else { return nil }
        // "The first meeting" is the first of something (a project, a client, a series): the first one ever recorded only by chance.
        if case .first = place.which, !place.ofNamed { return nil }
        return place
    }

    // MARK: Languages written with spaces

    /// One entry per meeting noun with a place word next to it: nil for a point in time.
    static func readLatin(_ tokens: [String], _ lexicon: AskPlaceWords.Lexicon, nouns: [[String]]) -> [AskMeetingPlace?] {
        var out: [AskMeetingPlace?] = []
        var taken: [Range<Int>] = []
        for noun in nouns.sorted(by: { $0.count > $1.count }) {
            for i in AskTimeScope.occurrences(of: noun, in: tokens) where !taken.contains(where: { $0.overlaps(i..<(i + noun.count)) }) {
                taken.append(i..<(i + noun.count))
                if let place = place(noun: i..<(i + noun.count), tokens, lexicon) { out.append(place.point ? nil : place.place) }
            }
        }
        return out
    }

    private static func place(noun: Range<Int>, _ tokens: [String], _ lexicon: AskPlaceWords.Lexicon) -> (place: AskMeetingPlace, point: Bool)? {
        var start = noun.lowerBound, end = noun.upperBound
        var count: Int?
        // "the last three meetings", "las tres reuniones anteriores".
        if start > 0, let n = AskTimeScope.number(tokens[start - 1]) { count = n; start -= 1 }
        var kind: AskPlaceWords.Kind?
        if let (length, k) = longest(lexicon.before, endingAt: start, tokens) {
            kind = k
            start -= length
            // "las tres últimas reuniones".
            if count == nil, start > 0, let n = AskTimeScope.number(tokens[start - 1]) { count = n; start -= 1 }
        } else if let (length, k) = longest(lexicon.after, startingAt: end, tokens) {
            kind = k
            end += length
        }
        guard let kind else { return nil }
        // "since the last meeting", "desde la última reunión", "dall'ultima riunione".
        var k = start
        if k > 0, lexicon.articles.contains(tokens[k - 1]) { k -= 1 }
        if AskTimeScope.leader(lexicon.around, endingAt: k, in: tokens) != nil {
            return (AskMeetingPlace(which: .last(1), ofNamed: false), true)
        }
        // "the first and the last meeting", "between the third and the last meeting", "from the second to the fourth meeting": the
        // question compares meetings, it does not name one set of them.
        if tokens.indices.contains(where: { !(start..<end).contains($0) && lexicon.ordinals.contains(tokens[$0]) }) {
            return (AskMeetingPlace(which: .last(1), ofNamed: false), true)
        }
        if let had = AskTimeScope.leader(lexicon.had, startingAt: end, in: tokens) { end += had }
        // "Ana's last meeting" (the English possessive), "the last meeting with Ana", "where we discussed Kobaltix".
        let ofNamed = (start > 0 && tokens[start - 1] == "s") || AskTimeScope.leader(lexicon.of, startingAt: end, in: tokens) != nil
        let n = min(count ?? (lexicon.plurals.contains(tokens[noun].joined(separator: " ")) ? 3 : 1), 20)
        let which: Which = switch kind {
        case .last: .last(n)
        case .first: .first(n)
        case .beforeLast: .beforeLast
        }
        return (AskMeetingPlace(which: which, ofNamed: ofNamed), false)
    }

    private static func longest(_ entries: [(words: [String], kind: AskPlaceWords.Kind)], endingAt index: Int, _ tokens: [String]) -> (Int, AskPlaceWords.Kind)? {
        entries.filter { $0.words.count <= index && tokens[(index - $0.words.count)..<index].elementsEqual($0.words) }
            .max { $0.words.count < $1.words.count }.map { ($0.words.count, $0.kind) }
    }

    private static func longest(_ entries: [(words: [String], kind: AskPlaceWords.Kind)], startingAt index: Int, _ tokens: [String]) -> (Int, AskPlaceWords.Kind)? {
        entries.filter { index + $0.words.count <= tokens.count && tokens[index..<(index + $0.words.count)].elementsEqual($0.words) }
            .max { $0.words.count < $1.words.count }.map { ($0.words.count, $0.kind) }
    }

    // MARK: Japanese, Korean and Chinese

    static func readScript(_ text: String, _ script: AskPlaceWords.Script, korean: Bool) -> [AskMeetingPlace?] {
        var hits: [(range: Range<String.Index>, kind: AskPlaceWords.Kind, count: Int?)] = []
        for (pattern, kind) in script.patterns {
            guard let regex = try? Regex(pattern) else { continue }
            for match in text.matches(of: regex) {
                let n = match.output["n"]?.substring.map(String.init).flatMap(AskTimeWords.cjkNumber)
                hits.append((match.range, kind, n))
            }
        }
        let kept = AskTimeScope.longestFirst(hits, length: { text.distance(from: $0.range.lowerBound, to: $0.range.upperBound) },
                                             overlaps: { $0.range.overlaps($1.range) })
        return kept.map { hit in
            let before = String(text[..<hit.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(text[hit.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if script.aroundAfter.contains(where: after.hasPrefix) || script.aroundBefore.contains(where: before.hasSuffix) { return nil }
            if let other = try? Regex(script.otherOrdinals), before.contains(other) || after.contains(other) { return nil }
            // "Anaとの前回の会議", "和Ana的上次会议", and a clause right before it ("予算を話し合った最後の会議", "논의한 지난 회의").
            let ofNamed = script.ofBefore.contains(where: before.hasSuffix) || before.last.map(script.modifierEnds.contains) == true
                || (korean && endsInModifier(before))
            let n = min(hit.count ?? 1, 20)
            let which: Which = switch hit.kind {
            case .last: .last(n)
            case .first: .first(n)
            case .beforeLast: .beforeLast
            }
            return AskMeetingPlace(which: which, ofNamed: ofNamed)
        }
    }

    /// Korean: the text before ends in an adnominal form (논의한, 했던, 하는, 할), a Hangul syllable whose final consonant is ㄴ or ㄹ.
    static func endsInModifier(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last, (0xAC00...0xD7A3).contains(scalar.value) else { return false }
        let final = (scalar.value - 0xAC00) % 28
        return final == 4 || final == 8
    }
}

extension MeetingStore {
    /// The ended meetings at `place`, newest first: the latest n, the first n or the one before the latest. `entities`: only the
    /// meetings that name all of them (as `MeetingFilter`); `from`, `to`: only those started then. The meeting being recorded is
    /// not one of them ("the last meeting" while recording is the one before).
    public func meetingIDs(at place: AskMeetingPlace.Which, entities: [Int64] = [], from: Date? = nil, to: Date? = nil) throws -> [Int64] {
        let candidates = try meetingIDs(matching: MeetingFilter(entities: entities, from: from, to: to))
        guard !candidates.isEmpty else { return [] }
        let ended = Set(try db.query("SELECT id FROM meetings WHERE ended_at IS NOT NULL AND id IN (SELECT value FROM json_each(?))",
                                     [.ids(candidates)]).map { $0.int(0) })
        let newest = candidates.filter(ended.contains)
        switch place {
        case .last(let n): return Array(newest.prefix(n))
        case .first(let n): return Array(newest.suffix(n))
        case .beforeLast: return newest.count >= 2 ? [newest[1]] : []
        }
    }
}
