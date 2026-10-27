// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Exact matcher of normalized alias keys in transcript text, shared by the
/// analysis, the suggestion resolver and question parsing.
///
/// - Spaced scripts: greedy longest n-gram of word tokens.
/// - Scripts without spaces (Han, Kana, Thai…): the tokenizer may split a name
///   ("王伟" → "王", "伟"), so tokens are joined without a separator and, for
///   keys of two or more characters, the normalized character run is also
///   searched directly.
///
/// Surfaces are always the original substring ("Jean-Luc", "王伟"), never
/// tokens re-joined with spaces.
struct NameMatcher<Value> {
    struct Match {
        let range: Range<String.Index>
        /// The canonical key (`TextKeys.matchKey` of the alias norm).
        let key: String
        let surface: String
        let values: [Value]
    }

    private var keys: [String: [Value]] = [:]
    /// Keys that are also function words of the meeting language ("yo",
    /// "will", "al"): they only match a token that looks like a name.
    private let gated: Set<String>
    private var maxTokens = 1
    /// No-space-script keys of ≥ 2 characters, by first character, longest first.
    private var runKeys: [Character: [[Character]]] = [:]

    /// `entries`: (alias norm, value). Several values may share a key (ambiguous names).
    /// `gated: false` matches function-word keys anywhere (the user confirmed that name).
    init(_ entries: [(norm: String, value: Value)], profile: LanguageProfile, gated gate: Bool = true) {
        var gated = Set<String>()
        for (norm, value) in entries {
            let key = TextKeys.matchKey(norm)
            guard !key.isEmpty else { continue }
            if keys[key] == nil {
                let chars = Array(key)
                // Upper bound of the tokens a key can span: words plus, for
                // no-space scripts, one token per character.
                let words = key.split(separator: " ").count
                let noSpace = chars.filter(TextKeys.isNoSpaceScript).count
                maxTokens = max(maxTokens, min(12, words + noSpace))
                if noSpace >= 2, noSpace == chars.count {
                    runKeys[chars[0], default: []].append(chars)
                }
                if gate, profile.stopwords.contains(key) { gated.insert(key) }
            }
            keys[key, default: []].append(value)
        }
        for k in runKeys.keys { runKeys[k]?.sort { $0.count > $1.count } }
        self.gated = gated
    }

    var isEmpty: Bool { keys.isEmpty }

    func values(for norm: String) -> [Value]? { keys[TextKeys.matchKey(norm)] }

    /// Non-overlapping matches in `text`, in text order. `tokens` must come
    /// from `TextKeys.tokens(text, profile:)`.
    func matches(in text: String, tokens: [TextKeys.Token], profile: LanguageProfile) -> [Match] {
        var out: [Match] = []
        var i = 0
        while i < tokens.count {
            var matched = false
            for n in stride(from: min(maxTokens, tokens.count - i), through: 1, by: -1) {
                let span = tokens[i..<i + n]
                let key = TextKeys.matchKey(span.map(\.norm).joined(separator: " "))
                guard let values = keys[key] else { continue }
                if gated.contains(key), !(n == 1 && profile.looksLikeName(tokens[i])) { continue }
                let range = span.first!.range.lowerBound..<span.last!.range.upperBound
                out.append(Match(range: range, key: key, surface: String(text[range]), values: values))
                i += n
                matched = true
                break
            }
            if !matched { i += 1 }
        }
        if !runKeys.isEmpty, text.unicodeScalars.contains(where: TextKeys.isNoSpaceScript) {
            out += runMatches(in: text, excluding: out.map(\.range))
            out.sort { $0.range.lowerBound < $1.range.lowerBound }
        }
        return out
    }

    /// Direct search over runs of no-space-script characters, for names the
    /// tokenizer split or merged with a neighbour.
    private func runMatches(in text: String, excluding taken: [Range<String.Index>]) -> [Match] {
        // Normalized character and original range of every no-space-script character.
        var chars: [(ch: Character, range: Range<String.Index>)] = []
        var out: [Match] = []
        func flushRun() {
            var p = 0
            while p < chars.count {
                var step = 1
                for candidate in runKeys[chars[p].ch] ?? [] where p + candidate.count <= chars.count {
                    guard zip(candidate, chars[p..<p + candidate.count]).allSatisfy({ $0 == $1.ch }) else { continue }
                    let range = chars[p].range.lowerBound..<chars[p + candidate.count - 1].range.upperBound
                    if !taken.contains(where: { $0.overlaps(range) }) {
                        let key = String(candidate)
                        out.append(Match(range: range, key: key, surface: String(text[range]), values: keys[key] ?? []))
                        step = candidate.count
                    }
                    break
                }
                p += step
            }
            chars.removeAll(keepingCapacity: true)
        }
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let ch = text[index]
            if TextKeys.isNoSpaceScript(ch), let folded = TextKeys.norm(String(ch)).first, TextKeys.isNoSpaceScript(folded) {
                chars.append((folded, index..<next))
            } else if !chars.isEmpty {
                flushRun()
            }
            index = next
        }
        if !chars.isEmpty { flushRun() }
        return out
    }
}
