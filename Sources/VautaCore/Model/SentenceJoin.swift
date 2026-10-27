// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension Sequence where Element == String {
    /// Joins sentences through a localized format, never with a hard-coded space: Japanese and
    /// Chinese put nothing between sentences, so their translation of the format has no space.
    public func joinedAsSentences() -> String {
        var result: String?
        for sentence in self where !sentence.isEmpty {
            if var current = result {
                if !current.endsWithSentenceMark {
                    // A short status ("No model chosen") joined to what to do about it needs its full stop.
                    current = String(localized: "\(current).", comment: "A sentence that has no full stop yet, closed. Japanese and Chinese use 。 here")
                }
                result = String(localized: "\(current) \(sentence)", comment: "Two sentences in a row (for example an error and what to do about it). Japanese and Chinese: no space between %1$@ and %2$@")
            } else {
                result = sentence
            }
        }
        return result ?? ""
    }
}

extension String {
    /// Whether the text already ends a sentence (also through closing quotes and brackets).
    var endsWithSentenceMark: Bool {
        let closers: Set<Character> = ["”", "’", "\"", "'", ")", "）", "」", "』", "»", "]"]
        let marks: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "．", ":", "：", ";", "；"]
        guard let last = last(where: { !closers.contains($0) }) else { return true }
        return marks.contains(last)
    }
}
