// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Joins the parts of a VoiceOver label ("Open System Settings, Microphone") with a plain pause. `ListFormatter` is not used here: for two
/// items it puts a conjunction between them, in the system's language rather than the app's ("Allow and Microphone").
public enum SpokenLabel {
    /// The separator of `language` (an app language code such as "ja"): the ideographic comma for Japanese and Chinese, a comma and a space otherwise.
    public static func separator(language: String) -> String {
        switch language.split(separator: "-").first.map(String.init) ?? language {
        case "ja", "zh": "、"
        default: ", "
        }
    }

    public static func join(_ parts: [String], language: String = Bundle.main.preferredLocalizations.first ?? "en") -> String {
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // A part that ends a sentence would read "the 28th., Proposed by": the full stop is dropped from every part but the last.
        let spoken = trimmed.enumerated().map { index, part in index == trimmed.count - 1 ? part : withoutFinalStop(part) }
        return spoken.joined(separator: separator(language: language))
    }

    private static func withoutFinalStop(_ part: String) -> String {
        guard let last = part.last, ".。．".contains(last), !part.hasSuffix("..") , !part.hasSuffix("…") else { return part }
        return String(part.dropLast()).trimmingCharacters(in: .whitespaces)
    }
}
