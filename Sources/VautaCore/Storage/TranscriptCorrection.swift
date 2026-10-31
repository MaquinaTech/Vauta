// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a correction of a transcript line changed, word by word. The words of the line before and after are aligned on their
/// `TextKeys.norm` forms (the longest common subsequence), so case, accents, punctuation and spacing never count as a change.
/// The alignment tells where a passage of the old line is in the new one, and which items written from the old line may no
/// longer say what the line says. Pure: no store, no model.
struct TranscriptCorrection {
    let old: String
    let new: String
    let oldTokens: [TextKeys.Token]
    let newTokens: [TextKeys.Token]
    /// For each word of the old line, the word it stayed as in the new one; nil when the correction removed or replaced it.
    let oldToNew: [Int?]
    /// For each word of the new line, the word it was; nil when the correction added it.
    let newToOld: [Int?]
    private let profile: LanguageProfile

    /// Beyond this many table cells the middle of two very long lines is not aligned word by word: it counts as replaced.
    static let maxCells = 2_000_000
    /// How many words on each side of the words an item shares with the line a change still reaches it ("not" before a verb).
    static let reach = 2
    /// Hesitation sounds (`TextKeys.norm`), the only words whose change never matters.
    static let hesitations: Set<String> = ["um", "umm", "uh", "uhm", "hm", "hmm", "mm", "mhm", "er", "erm", "ah", "eh", "ehm", "em", "euh", "ahm"]

    init(from old: String, to new: String, profile: LanguageProfile) {
        self.old = old
        self.new = new
        self.profile = profile
        let a = TextKeys.tokens(old, profile: profile), b = TextKeys.tokens(new, profile: profile)
        oldTokens = a
        newTokens = b
        var oldToNew = [Int?](repeating: nil, count: a.count), newToOld = [Int?](repeating: nil, count: b.count)
        // The same words at both ends need no table.
        var head = 0
        while head < a.count, head < b.count, a[head].norm == b[head].norm {
            oldToNew[head] = head
            newToOld[head] = head
            head += 1
        }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail].norm == b[b.count - 1 - tail].norm {
            oldToNew[a.count - 1 - tail] = b.count - 1 - tail
            newToOld[b.count - 1 - tail] = a.count - 1 - tail
            tail += 1
        }
        let (n, m) = (a.count - head - tail, b.count - head - tail)
        if n > 0, m > 0, (n + 1) * (m + 1) <= Self.maxCells {
            // lengths[i * width + j]: the longest common subsequence of the middle words from i (old) and j (new) on.
            let width = m + 1
            var lengths = [Int32](repeating: 0, count: (n + 1) * width)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lengths[i * width + j] = a[head + i].norm == b[head + j].norm
                        ? lengths[(i + 1) * width + j + 1] + 1
                        : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
                }
            }
            var (i, j) = (0, 0)
            while i < n, j < m {
                if a[head + i].norm == b[head + j].norm {
                    oldToNew[head + i] = head + j
                    newToOld[head + j] = head + i
                    i += 1
                    j += 1
                } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        self.oldToNew = oldToNew
        self.newToOld = newToOld
    }

    /// The correction changed words, not only case, accents, punctuation or spacing.
    var changesWords: Bool { oldToNew.contains(nil) || newToOld.contains(nil) }

    /// Whether an item written from the old line (a decision, a task, a sentence of a note's expansion) may no longer say what
    /// the line says:
    /// - a figure it gives was in the old line and is not in the new one ("15" → "50"; `MinutesVerifier`);
    /// - the correction removed, replaced or added a word (other than a hesitation) among the words the item shares with the line,
    ///   or within `reach` words of them: a name ("Ana" → "Anna"), a term, a "not" added before the verb;
    /// - it shares no word with the line (the minutes are in another language, or say it in other words) and the correction
    ///   changed a word that carries meaning.
    /// Hesitations ("um", "eh"), case, accents and punctuation alone touch nothing.
    func touches(_ item: String) -> Bool {
        guard changesWords else { return false }
        let languages = [profile.languageCode]
        if MinutesVerifier.figuresAreInSegment(item: item, segment: old, spokenIn: languages),
           !MinutesVerifier.figuresAreInSegment(item: item, segment: new, spokenIn: languages) { return true }
        let words = Set(TextKeys.tokens(item, profile: profile).map(\.norm))
        let shared = oldTokens.indices.filter { words.contains(oldTokens[$0].norm) && carriesMeaning(oldTokens[$0].norm) }
        guard let first = shared.first, let last = shared.last else {
            return oldTokens.indices.contains { oldToNew[$0] == nil && carriesMeaning(oldTokens[$0].norm) }
                || newTokens.indices.contains { newToOld[$0] == nil && carriesMeaning(newTokens[$0].norm) }
        }
        let near = (first - Self.reach)...(last + Self.reach)
        if oldTokens.indices.contains(where: { near.contains($0) && oldToNew[$0] == nil && !Self.hesitations.contains(oldTokens[$0].norm) }) {
            return true
        }
        // An added word sits before the old word that follows it (the count of old words before it).
        return newTokens.indices.contains { j in
            guard newToOld[j] == nil, !Self.hesitations.contains(newTokens[j].norm) else { return false }
            let before = (0..<j).reversed().lazy.compactMap { self.newToOld[$0] }.first.map { $0 + 1 } ?? 0
            return (near.lowerBound...(near.upperBound + 1)).contains(before)
        }
    }

    /// Where the correction put other words in place of some (a misheard name or term), as written in each line: at most
    /// `maxWords` on each side, with an old word that carries meaning. Words only added or only removed are not replacements.
    func replacements(maxWords: Int = 3) -> [(from: String, to: String)] {
        var out: [(from: String, to: String)] = []
        var (i, j) = (0, 0)
        while i < oldTokens.count || j < newTokens.count {
            if i < oldTokens.count, j < newTokens.count, oldToNew[i] == j {
                i += 1
                j += 1
                continue
            }
            let (i0, j0) = (i, j)
            while i < oldTokens.count, oldToNew[i] == nil { i += 1 }
            while j < newTokens.count, newToOld[j] == nil { j += 1 }
            guard i > i0 || j > j0 else { break }
            guard i > i0, j > j0, i - i0 <= maxWords, j - j0 <= maxWords,
                  (i0..<i).contains(where: { carriesMeaning(oldTokens[$0].norm) }) else { continue }
            out.append((String(old[oldTokens[i0].range.lowerBound..<oldTokens[i - 1].range.upperBound]),
                        String(new[newTokens[j0].range.lowerBound..<newTokens[j - 1].range.upperBound])))
        }
        return out
    }

    /// `text` with every run of whole words that reads `from` (`TextKeys.norm`) written as `to`; nil when it has none. A place
    /// that already reads `to` ("Ana María" for "Ana" → "Ana María") is left as it is.
    static func replacing(_ from: String, with to: String, in text: String, profile: LanguageProfile) -> String? {
        let words = TextKeys.tokens(from, profile: profile).map(\.norm)
        let target = TextKeys.tokens(to, profile: profile).map(\.norm)
        let tokens = TextKeys.tokens(text, profile: profile)
        guard !words.isEmpty, tokens.count >= words.count else { return nil }
        func reads(_ phrase: [String], at start: Int) -> Bool {
            start + phrase.count <= tokens.count && phrase.indices.allSatisfy { tokens[start + $0].norm == phrase[$0] }
        }
        var ranges: [Range<String.Index>] = []
        var start = 0
        while start + words.count <= tokens.count {
            if !target.isEmpty, reads(target, at: start) {
                start += target.count
            } else if reads(words, at: start) {
                ranges.append(tokens[start].range.lowerBound..<tokens[start + words.count - 1].range.upperBound)
                start += words.count
            } else {
                start += 1
            }
        }
        guard !ranges.isEmpty else { return nil }
        var out = text
        for r in ranges.reversed() { out.replaceSubrange(r, with: to) }
        return out
    }

    private func carriesMeaning(_ norm: String) -> Bool {
        !profile.stopwords.contains(norm) && !Self.hesitations.contains(norm)
    }

    /// Where a passage of the old line is in the new one: from its first word to its last through the alignment (a word the
    /// correction replaced takes its replacement), with the punctuation around them when the new line has it there too. nil
    /// when the passage has no word or the correction removed all of them.
    func newRange(of range: Range<String.Index>) -> Range<String.Index>? {
        let inside = oldTokens.indices.filter { oldTokens[$0].range.overlaps(range) }
        guard let first = inside.first, let last = inside.last else { return nil }
        let lo = oldToNew[first] ?? ((0..<first).reversed().lazy.compactMap { self.oldToNew[$0] }.first.map { $0 + 1 } ?? 0)
        let hi = oldToNew[last] ?? (((last + 1)..<oldTokens.count).lazy.compactMap { self.oldToNew[$0] }.first.map { $0 - 1 } ?? newTokens.count - 1)
        guard lo <= hi, hi < newTokens.count else { return nil }
        var lower = newTokens[lo].range.lowerBound, upper = newTokens[hi].range.upperBound
        if range.lowerBound < oldTokens[first].range.lowerBound {
            let lead = old[range.lowerBound..<oldTokens[first].range.lowerBound]
            if new[..<lower].hasSuffix(lead) { lower = new.index(lower, offsetBy: -lead.count) }
        }
        if oldTokens[last].range.upperBound < range.upperBound {
            let trail = old[oldTokens[last].range.upperBound..<range.upperBound]
            if new[upper...].hasPrefix(trail) { upper = new.index(upper, offsetBy: trail.count) }
        }
        return lower..<upper
    }

    /// A passage quoted from the old line, as the new line says it: found as written, else word by word (`TextKeys.norm`).
    /// nil when it is not in the old line or the correction removed all of it.
    func corrected(quote: String) -> String? {
        if let r = old.range(of: quote) { return newRange(of: r).map { String(new[$0]) } }
        let words = TextKeys.tokens(quote, profile: profile).map(\.norm)
        guard !words.isEmpty, words.count <= oldTokens.count else { return nil }
        for start in 0...(oldTokens.count - words.count)
        where words.indices.allSatisfy({ oldTokens[start + $0].norm == words[$0] }) {
            return newRange(of: oldTokens[start].range.lowerBound..<oldTokens[start + words.count - 1].range.upperBound).map { String(new[$0]) }
        }
        return nil
    }

    /// Where to cut the old line when the new one is cut at `index` (a split of a corrected line cuts what the transcriber
    /// wrote at the same word). Words the correction replaced just before the cut stay on the left with their replacement.
    func oldCut(atNew index: String.Index) -> String.Index {
        let k = newTokens.prefix { $0.range.upperBound <= index }.count
        guard k > 0 else { return old.startIndex }
        let b: Int
        if let kept = newToOld[k - 1] {
            b = kept + 1
        } else {
            b = (k..<newTokens.count).lazy.compactMap { self.newToOld[$0] }.first ?? oldTokens.count
        }
        return b < oldTokens.count ? oldTokens[b].range.lowerBound : old.endIndex
    }
}
