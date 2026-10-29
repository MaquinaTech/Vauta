// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// The keys links are made from. Pure, deterministic and the same for every device.
enum LinkText {
    /// Content words for the keyword gate and the lexical support of a vector pair: the folded words of the item without its stopwords, the
    /// scripts written without spaces as character pairs, and **without numbers or anything with a digit** (a figure that changed must
    /// not lower the overlap of two texts about the same thing; `LinkDifference` reads the figures).
    static func words(_ text: String, locale: String) -> Set<String> {
        QuestionDedup.keys(text, locale: locale).filter { !$0.contains(where: \.isNumber) }
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Codes (ticket numbers, invoice ids) and capitalised names of a text, folded: a shared one is a rare anchor.
    static func anchors(_ text: String, locale: String) -> Set<String> {
        var out = Set(SemanticRanker.codes(in: text).map { TextKeys.norm($0) })
        out.formUnion(BriefKeywordGate.names(in: text, locale: locale))
        return out
    }

    /// The text an item is embedded from (recipe 1): its words only, cleaned, one line, 1,000 characters at most (the search model cuts the
    /// sequence at 512 tokens itself, `SearchModelManifest.maxSequence`). The owner and the due day are compared apart, never embedded.
    static func embeddingText(_ text: String) -> String {
        TextSanitizer.oneLine(text, limit: 1_000)
    }

    /// The content key of an item for a dismissal: the SHA-256 of its normalized words. A hash only, never the words.
    static func key(_ text: String) -> String {
        SHA256.hash(data: Data(TextKeys.norm(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The language of an item: detected when the recognizer is sure, else the meeting's.
    static func language(of text: String, fallback: Locale) -> String {
        let fallbackLanguage = OutputLanguage(fallback)
        let detected = OutputLanguage.detect(text, fallback: fallbackLanguage)
        return Locale(identifier: detected.identifier).language.languageCode?.identifier ?? "und"
    }

    /// Whether an edit moved an item away from its text: content-word Jaccard under 0.5 (small edits keep what the person confirmed).
    static func isSubstantialEdit(from old: String, to new: String, locale: String) -> Bool {
        let a = QuestionDedup.keys(old, locale: locale), b = QuestionDedup.keys(new, locale: locale)
        guard !a.isEmpty || !b.isEmpty else { return old != new }
        return jaccard(a, b) < 0.5
    }
}
