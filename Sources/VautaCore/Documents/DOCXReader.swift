// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Word documents (`.docx`, `.dotx`): paragraphs under their headings, tables row by row ("cell | cell"). Hidden runs
/// (`w:vanish`), deleted text, field codes and the fallback copy of a text box are not read. Footnotes and comments are
/// not read in this version.
enum DOCXReader {
    static func read(_ zip: SafeZip, clock: ExtractionClock) throws -> ExtractedDocument {
        guard let body = try zip.read("word/document.xml", maxBytes: 64 << 20) else { throw DocumentExtractionError(.unreadable) }
        let styles = try readStyles(zip, clock: clock)
        let builder = Builder(levels: styles.levels, hidden: styles.hidden)
        try SafeXML.parse(body, limits: clock.xmlLimits, start: { builder.start($0, $1) }, end: { builder.end($0) }, text: { builder.text($0) })
        builder.finish()
        guard !builder.units.isEmpty else { throw DocumentExtractionError(.noText) }
        return ExtractedDocument(title: OOXML.title(in: zip) ?? builder.title, units: builder.units, partial: builder.partial)
    }

    /// Style id → heading level (1...9), from `styles.xml`: by the style's English name ("heading 2"), or by an id that
    /// is itself `Heading2`; and the styles that hide their text (`w:vanish` in the style or in one it is based on), which Word does
    /// not show and Vauta does not read.
    private static func readStyles(_ zip: SafeZip, clock: ExtractionClock) throws -> (levels: [String: Int], hidden: Set<String>) {
        guard let data = try zip.read("word/styles.xml", maxBytes: 16 << 20) else { return ([:], []) }
        var out: [String: Int] = [:]
        var currentID: String?
        var vanishing = Set<String>()
        var basedOn: [String: String] = [:]
        try SafeXML.parse(data, limits: clock.xmlLimits, start: { name, attrs in
            if name == "style" { currentID = attrs.value("styleId") }
            if name == "name", let id = currentID, let value = attrs.value("val")?.lowercased() {
                if value.hasPrefix("heading "), let level = Int(value.dropFirst(8)), (1...9).contains(level) { out[id] = level }
                if value == "title" { out[id] = 0 }
            }
            if name == "basedOn", let id = currentID, let parent = attrs.value("val") { basedOn[id] = parent }
            if name == "vanish", let id = currentID, !["0", "false", "off"].contains((attrs.value("val") ?? "1").lowercased()) { vanishing.insert(id) }
        }, end: { if $0 == "style" { currentID = nil } })
        var hidden = Set<String>()
        for id in Set(basedOn.keys).union(vanishing) {
            var step = id
            for _ in 0..<12 {
                if vanishing.contains(step) { hidden.insert(id); break }
                guard let parent = basedOn[step] else { break }
                step = parent
            }
        }
        return (out, hidden)
    }

    private final class Builder {
        let levels: [String: Int]
        let hiddenStyles: Set<String>
        var units: [DocumentUnit] = []
        var title: String?
        var partial = false
        private var path: [String] = []
        private var lines: [String] = []
        private var firstBlock = 1
        private var blocks = 0
        private var characters = 0
        // Paragraphs can nest (a text box inside a run): a stack of the ones open.
        private var paragraphs: [Paragraph] = []
        private var runHidden = false
        private var runStyleHidden = false
        private var inText = false
        private var fallbackDepth = 0
        private var tableDepth = 0
        private var rowCells: [String] = []
        private var cellParts: [String] = []

        struct Paragraph { var text = ""; var level: Int?; var hidden = false }

        init(levels: [String: Int], hidden: Set<String>) {
            self.levels = levels
            hiddenStyles = hidden
        }

        func start(_ name: String, _ attrs: SafeXML.Attributes) {
            switch name {
            case "Fallback": fallbackDepth += 1
            case "p": paragraphs.append(Paragraph())
            case "pStyle":
                if !paragraphs.isEmpty, let id = attrs.value("val") {
                    if hiddenStyles.contains(id) { paragraphs[paragraphs.count - 1].hidden = true }
                    let level = levels[id] ?? (id.hasPrefix("Heading") ? Int(id.dropFirst(7)) : nil)
                    if let level, level <= 9 { paragraphs[paragraphs.count - 1].level = level }
                }
            case "r": runHidden = false; runStyleHidden = false
            case "rStyle": if let id = attrs.value("val"), hiddenStyles.contains(id) { runStyleHidden = true }
            case "vanish": runHidden = !["0", "false", "off"].contains((attrs.value("val") ?? "1").lowercased())
            case "t": inText = true
            case "tab": append("\t")
            case "br", "cr": append(" ")
            case "tbl": tableDepth += 1
            case "tr": if tableDepth == 1 { rowCells = [] }
            case "tc": if tableDepth == 1 { cellParts = [] }
            default: break
            }
        }

        func end(_ name: String) {
            switch name {
            case "Fallback": fallbackDepth = max(0, fallbackDepth - 1)
            case "t": inText = false
            case "r": runHidden = false; runStyleHidden = false
            case "p":
                guard let done = paragraphs.popLast() else { return }
                finish(paragraph: done)
            case "tc":
                if tableDepth == 1 { rowCells.append(cellParts.joined(separator: " ")) }
            case "tr":
                if tableDepth == 1 {
                    let row = rowCells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " | ")
                    if !row.isEmpty { add(line: row) }
                }
            case "tbl": tableDepth = max(0, tableDepth - 1)
            default: break
            }
        }

        func text(_ string: String) {
            guard inText, !runHidden, !runStyleHidden, fallbackDepth == 0 else { return }
            append(string)
        }

        private func append(_ string: String) {
            guard !runHidden, !runStyleHidden, fallbackDepth == 0, !paragraphs.isEmpty else { return }
            paragraphs[paragraphs.count - 1].text += string
        }

        private func finish(paragraph: Paragraph) {
            guard !paragraph.hidden else { return }
            let text = TextSanitizer.clean(paragraph.text).split(whereSeparator: { $0 == "\t" || $0 == " " }).joined(separator: " ")
            guard !text.isEmpty else { return }
            if tableDepth > 0 {
                // Inside a table the paragraph is part of its cell; a nested table's text lands in the outer cell.
                if tableDepth == 1 { cellParts.append(text) } else if !cellParts.isEmpty { cellParts[cellParts.count - 1] += " " + text }
                return
            }
            if let level = paragraph.level {
                if level == 0 { if title == nil { title = TextSanitizer.oneLine(text, limit: 160) } }
                flushUnit()
                if level > 0 {
                    path = Array(path.prefix(level - 1)) + [TextSanitizer.oneLine(text, limit: 120)]
                } else {
                    path = []
                }
                return
            }
            add(line: text)
        }

        private func add(line: String) {
            guard !partial else { return }
            if characters + line.count > DocumentLimits.maxCharactersPerFile { partial = true; return }
            if lines.isEmpty { firstBlock = blocks + 1 }
            blocks += 1
            characters += line.count
            lines.append(line)
        }

        private func flushUnit() {
            guard !lines.isEmpty else { return }
            units.append(DocumentUnit(locator: .section(path: path, block: firstBlock), text: lines.joined(separator: "\n"),
                                      headings: path, firstBlock: firstBlock))
            lines = []
        }

        func finish() { flushUnit() }
    }
}
