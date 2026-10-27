// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Collects the lines of running text (Markdown, HTML, plain text, RTF) into units, one per heading section, each with
/// the heading path it sits under and the number of its first paragraph.
struct RunningTextBuilder {
    private(set) var units: [DocumentUnit] = []
    private(set) var partial = false
    private(set) var title: String?
    private var path: [String] = []
    private var lines: [String] = []
    private var firstBlock = 1
    private var blocks = 0
    private var characters = 0

    var isEmpty: Bool { units.isEmpty && lines.isEmpty }

    mutating func add(line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !partial else { return }
        if characters + text.count > DocumentLimits.maxCharactersPerFile { partial = true; return }
        if lines.isEmpty { firstBlock = blocks + 1 }
        blocks += 1
        characters += text.count
        lines.append(text)
    }

    /// A heading: it closes the section before it and opens the one it names (level 1...9).
    mutating func heading(level: Int, text: String) {
        let clean = TextSanitizer.oneLine(text, limit: 120)
        guard !clean.isEmpty else { return }
        flush()
        if title == nil, level == 1 { title = TextSanitizer.oneLine(clean, limit: 160) }
        path = Array(path.prefix(max(0, level - 1))) + [clean]
        // Passages of the section start counting from the heading's own paragraph.
        blocks += 1
    }

    mutating func flush() {
        guard !lines.isEmpty else { return }
        units.append(DocumentUnit(locator: .section(path: path, block: firstBlock), text: lines.joined(separator: "\n"),
                                  headings: path, firstBlock: firstBlock))
        lines = []
    }

    mutating func finish() -> [DocumentUnit] {
        flush()
        return units
    }
}
