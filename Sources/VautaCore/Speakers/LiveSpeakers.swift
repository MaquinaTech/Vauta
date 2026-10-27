// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Speakers while a meeting is being recorded. The live labels are provisional: the final clustering at the end may
/// merge, split or renumber them, so what the user typed against a live label is carried over by where the voice
/// was heard, never by its number.
public enum LiveSpeakers {
    /// The voice the name field is for. What the user picked wins; then the voice pinned while they type or point at the
    /// naming tools (so a voice heard meanwhile never takes the name they are writing); else the voice heard last.
    /// nil while no voice is told apart.
    public static func namingTarget(speakers: [Int], chosen: Int?, pinned: Int?, latest: Int?) -> Int? {
        guard !speakers.isEmpty else { return nil }
        for candidate in [chosen, pinned] {
            if let candidate, speakers.contains(candidate) { return candidate }
        }
        return latest.flatMap { speakers.contains($0) ? $0 : nil } ?? speakers.first
    }

    /// The label of a line in the live transcript: the name the user gave the provisional speaker, else the default
    /// label ("Me", "Speaker 2"). Without a speaker tag, the channel's name, as before speakers existed.
    public static func label(channel: Channel, speaker: SpeakerTag?, names: [Int: String]) -> String {
        guard let speaker else { return channel.displayName }
        if channel == .others, let name = names[speaker.ordinal] { return name }
        return speaker.displayName(channel: channel)
    }

    /// A stretch of the live transcript said by a provisional speaker of the other participants.
    public struct LiveSpan: Sendable, Equatable {
        public var ordinal: Int
        public var start: Double
        public var end: Double
        public init(ordinal: Int, start: Double, end: Double) {
            self.ordinal = ordinal
            self.start = start
            self.end = end
        }
    }

    /// A stretch of the saved transcript with its final speaker (other participants only).
    public struct StoredSpan: Sendable, Equatable {
        public var speakerID: Int64
        /// The speaker already has a person (the user named it): that assignment is never replaced.
        public var hasPerson: Bool
        public var start: Double
        public var end: Double
        public init(speakerID: Int64, hasPerson: Bool, start: Double, end: Double) {
            self.speakerID = speakerID
            self.hasPerson = hasPerson
            self.start = start
            self.end = end
        }
    }

    /// Which final speaker is the person the user named while recording: the one that holds most of the time the
    /// provisional speaker talked. A person goes to one speaker and a speaker gets one person; the best overlaps win.
    /// A final speaker that already has a person is left alone (user assignments win). `named`: provisional ordinal
    /// → person. `alreadyNamed`: the people other speakers of the meeting already hold; a person is never given to a
    /// second speaker (that is a merge, which only the user decides).
    public static func carryOver(named: [Int: Int64], live: [LiveSpan], stored: [StoredSpan], alreadyNamed: Set<Int64> = []) -> [(speakerID: Int64, entityID: Int64)] {
        struct Pair: Hashable { var ordinal: Int; var speakerID: Int64 }
        var overlap: [Pair: Double] = [:]
        for span in live where named[span.ordinal] != nil {
            for other in stored where !other.hasPerson {
                let shared = min(span.end, other.end) - max(span.start, other.start)
                if shared > 0 { overlap[Pair(ordinal: span.ordinal, speakerID: other.speakerID), default: 0] += shared }
            }
        }
        var takenOrdinals = Set<Int>(), takenSpeakers = Set<Int64>(), takenPeople = alreadyNamed
        var result: [(speakerID: Int64, entityID: Int64)] = []
        // Ties by ordinal then speaker, so the answer never depends on dictionary order.
        for (pair, _) in overlap.sorted(by: { ($0.value, -Double($0.key.ordinal), -Double($0.key.speakerID)) > ($1.value, -Double($1.key.ordinal), -Double($1.key.speakerID)) }) {
            guard let person = named[pair.ordinal], !takenOrdinals.contains(pair.ordinal), !takenSpeakers.contains(pair.speakerID),
                  !takenPeople.contains(person) else { continue }
            takenOrdinals.insert(pair.ordinal)
            takenSpeakers.insert(pair.speakerID)
            takenPeople.insert(person)
            result.append((pair.speakerID, person))
        }
        return result
    }
}

/// The speaker's name in a caption: one short line that never takes the room of the sentence.
public enum CaptionSpeakerName {
    /// Room for a name, in Latin letters; a character of a wide script (Chinese, Japanese, Korean) takes two.
    public static let limit = 16

    /// The name cut at a character, with an ellipsis, when it does not fit the limit.
    public static func short(_ name: String, limit: Int = CaptionSpeakerName.limit) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name that does not fit gives up its title first: “Dr. Alexandria M…” says less than “Alexandria Mont…”.
        if width(of: trimmed) > limit { trimmed = withoutTitle(trimmed) }
        var used = 0
        var out = ""
        for character in trimmed {
            let width = isWide(character) ? 2 : 1
            if used + width > limit {
                return out.trimmingCharacters(in: .whitespaces) + "…"
            }
            used += width
            out.append(character)
        }
        return out
    }

    /// The name for a caption whose sentence is cut (it starts with an ellipsis): a name cut mid-word gives up the partial
    /// word, so two ellipses never sit side by side. A name that was not cut, or has one word only, stays as it is.
    public static func beforeCutSentence(_ short: String) -> String {
        guard short.hasSuffix("…") else { return short }
        let body = short.dropLast()
        guard let space = body.lastIndex(of: " ") else { return short }
        return String(body[..<space]).trimmingCharacters(in: .whitespaces)
    }

    private static func width(of text: String) -> Int { text.reduce(0) { $0 + (isWide($1) ? 2 : 1) } }

    /// Titles that lead a name in the languages of the app (with or without the full stop).
    private static let titles: Set<String> = [
        "dr", "dra", "drs", "prof", "profa", "mr", "mrs", "ms", "miss", "mx", "sr", "sra", "srta", "dott", "dott.ssa", "dottssa", "sig", "sig.ra", "sigra",
        "m", "mme", "mlle", "me", "pr", "herr", "frau", "dipl.-ing", "dna", "dom", "lic", "ing", "arq", "eng", "eng.ª", "dr.ª", "sr.ª", "sra.",
    ]

    /// The name without a leading title (“Dr.”, “Dott.ssa”, “Frau”), when something else is left.
    static func withoutTitle(_ name: String) -> String {
        let words = name.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2 else { return name }
        let first = words[0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard titles.contains(first) || titles.contains(words[0].lowercased()) else { return name }
        return words.dropFirst().joined(separator: " ")
    }

    /// Stands for a shown name while a caption is laid out: one unbreakable word of `count` letters, with no punctuation
    /// (so no sentence ends inside it), then a space of fixed width. The caller chooses `count` so the marker is as wide
    /// as the name drawn in its place.
    public static func marker(count: Int) -> String {
        String(repeating: "l", count: max(1, count)) + "\u{2002}"
    }

    /// `text` is what the layout chose to show of a caption that started with `marker`; `real` is the caption's own text.
    /// Returns the text without the marker and whether the whole caption, name included, is shown. A caption cut to its
    /// last lines never shows the name, and never a part of its marker.
    public static func unmarked(_ text: String, real: String, marker: String) -> (text: String, isWhole: Bool) {
        if text.hasPrefix(marker) { return (String(text.dropFirst(marker.count)), true) }
        let cut = text.hasPrefix("…")
        let core = cut ? String(text.dropFirst()) : text
        guard core.count > real.count else { return (text, false) }
        return ((cut ? "…" : "") + String(core.suffix(real.count)), false)
    }

    private static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFF60, 0xFFE0...0xFFE6: true
            default: false
            }
        }
    }
}
