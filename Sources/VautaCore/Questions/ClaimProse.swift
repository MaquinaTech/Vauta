// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The prose of an answer built from its claims' texts.
public enum ClaimProse {
    /// The texts joined with a space, except after a full stop, question mark or exclamation mark of Japanese, Korean or Chinese
    /// punctuation (no space follows it in those scripts). A claim that does not end a sentence (models often leave the final stop out)
    /// gets one before the next claim follows: "。" after Japanese or Chinese text, "." otherwise.
    public static func join(_ texts: [String]) -> String {
        var out = ""
        for text in texts {
            if !out.isEmpty { out = terminated(out) }
            if let last = out.last, !"。！？".contains(last) { out += " " }
            out += text
        }
        return out
    }

    private static let enders: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "．"]
    private static let closers: Set<Character> = ["\"", "”", "’", "»", "'", ")", "）", "]", "」", "』", "›"]

    private static func terminated(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        var core = trimmed
        while let last = core.last, closers.contains(last) { core = core.dropLast() }
        guard let last = core.last, !enders.contains(last) else { return String(trimmed) }
        let cjk = last.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        return String(trimmed) + (cjk ? "。" : ".")
    }
}
