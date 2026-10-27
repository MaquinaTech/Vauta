// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Text that must stay on one line (titles, tasks, questions, subtitle cues).
public enum SingleLineText {
    /// Replaces every kind of line break (LF, CR, CRLF, NEL, U+2028 LINE
    /// SEPARATOR, U+2029 PARAGRAPH SEPARATOR, vertical tab, form feed) with a
    /// single space, collapsing runs of breaks.
    public static func flatten(_ text: String) -> String {
        guard text.contains(where: isBreak) else { return text }
        var out = ""
        var lastWasBreak = false
        for c in text {
            if isBreak(c) {
                if !lastWasBreak && !(out.last?.isWhitespace ?? true) { out.append(" ") }
                lastWasBreak = true
            } else {
                if lastWasBreak && c.isWhitespace && out.last == " " { continue }
                out.append(c)
                lastWasBreak = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Joins the lines with `separator` instead of a space (a pasted list of
    /// one item per line keeps its items apart). Empty lines are dropped.
    public static func flatten(_ text: String, separator: String) -> String {
        guard separator != " " else { return flatten(text) }
        guard text.contains(where: isBreak) else { return text }
        return text.split(whereSeparator: isBreak)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    /// True when the text contains a line break of any kind.
    public static func containsBreak(_ text: String) -> Bool { text.contains(where: isBreak) }

    private static func isBreak(_ c: Character) -> Bool {
        c.isNewline || c == "\u{0B}" || c == "\u{0C}"
    }
}
