// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The order of language names in every list of languages. Names sort alphabetically, and in Japanese by their kana
/// reading: kanji names sort by code point otherwise, so 韓国語 would come after ロシア語 instead of among the か row.
public enum LanguageNameSort {
    /// What a language name sorts by: the name itself, or in Japanese its reading in hiragana.
    public static func key(_ name: String, locale: Locale = .current) -> String {
        guard locale.language.languageCode?.identifier == "ja" else { return name }
        let text = name as CFString
        let length = CFStringGetLength(text)
        let tokenizer = CFStringTokenizerCreate(nil, text, CFRangeMake(0, length), kCFStringTokenizerUnitWordBoundary,
                                                Locale(identifier: "ja") as CFLocale)
        var reading = ""
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                reading += latin
            } else {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                reading += (name as NSString).substring(with: NSRange(location: range.location, length: range.length))
            }
        }
        return reading.applyingTransform(.latinToHiragana, reverse: false) ?? name
    }

    /// Whether `a` comes before `b` in a list of language names.
    public static func precedes(_ a: String, _ b: String, locale: Locale = .current) -> Bool {
        key(a, locale: locale).localizedStandardCompare(key(b, locale: locale)) == .orderedAscending
    }
}
