// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Figures said in words. Transcripts often write a number as it was said ("ninety one percent", "a las seis"), while an answer
/// writes it with digits ("91 %", "6"): the number is in the segment all the same.
extension MinutesVerifier {
    /// Whether `figure` (a key of `figures(in:)`: digits only) is written in words in `words` (`spelledWords` of the segment), in
    /// one of `languages`. Only whole numbers below ten million, spelled as Foundation spells them in that language (hyphens
    /// read as spaces): "12.50" (the key 1250) or "007" are not looked for in words.
    static func isSpelled(_ figure: String, in words: String, languages: [String]) -> Bool {
        guard figure.count <= 7, figure == "0" || figure.first != "0", let value = Int(figure) else { return false }
        return languages.contains { language in spelling(value, language).map { words.contains(" \($0) ") } ?? false }
    }

    /// A text as words to search in: normalized (`TextKeys.norm`), one space between words and one at each end. Soft hyphens
    /// go first: Foundation writes "ein\u{AD}und\u{AD}zwanzig" and "novant\u{AD}uno", one word each.
    static func spelledWords(_ text: String) -> String {
        let joined = text.replacingOccurrences(of: "\u{AD}", with: "")
        return " " + TextKeys.norm(joined).split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
    }

    private static func spelling(_ value: Int, _ language: String) -> String? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: language)
        guard let spelled = formatter.string(from: NSNumber(value: value)) else { return nil }
        let words = spelledWords(spelled).trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words
    }
}
