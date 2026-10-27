// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Plain text, Markdown, CSV/TSV and the formats macOS reads as attributed strings (RTF, legacy Word).
enum TextExtractors {
    // MARK: Plain text

    /// Longest run of text handed to the line readers whole; a longer line is cut (a hostile file can be one 50 MB line).
    static let maxLineLength = 10_000

    /// The lines of `text`, none longer than `maxLineLength`, checking the clock as it goes.
    static func lines(of text: String, clock: ExtractionClock) throws -> [String] {
        var out: [String] = []
        var count = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            count += 1
            if count % 512 == 0 { try clock.check() }
            if raw.count <= maxLineLength { out.append(String(raw)); continue }
            var rest = Substring(raw)
            while !rest.isEmpty {
                let piece = rest.prefix(maxLineLength)
                out.append(String(piece))
                rest = rest.dropFirst(maxLineLength)
            }
        }
        return out
    }

    static func plain(_ text: String, clock: ExtractionClock = ExtractionClock(seconds: DocumentLimits.textExtractionSeconds)) throws -> ExtractedDocument {
        var builder = RunningTextBuilder()
        for line in try lines(of: TextSanitizer.clean(text), clock: clock) { builder.add(line: line) }
        try clock.check()
        let units = builder.finish()
        guard !units.isEmpty else { throw DocumentExtractionError(.noText) }
        return ExtractedDocument(units: units, partial: builder.partial)
    }

    // MARK: Markdown

    /// `#` headings become the section path; emphasis marks, link targets, image targets and HTML comments are dropped
    /// (a comment is invisible when the page is shown, so it is not read). Code blocks are kept as they are.
    static func markdown(_ text: String, clock: ExtractionClock = ExtractionClock(seconds: DocumentLimits.textExtractionSeconds)) throws -> ExtractedDocument {
        var builder = RunningTextBuilder()
        var inFence = false
        let cleaned = removingComments(TextSanitizer.clean(text))
        try clock.check()
        for (number, line) in try lines(of: cleaned, clock: clock).enumerated() {
            if number % 256 == 0 { try clock.check() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { builder.add(line: line); continue }
            if let level = headingLevel(trimmed) {
                builder.heading(level: level, text: stripInline(String(trimmed.drop { $0 == "#" })))
                continue
            }
            // Horizontal rules and table separators carry nothing.
            if trimmed.allSatisfy({ "-*_=|: ".contains($0) }) { continue }
            builder.add(line: stripInline(line))
        }
        let units = builder.finish()
        guard !units.isEmpty else { throw DocumentExtractionError(.noText) }
        return ExtractedDocument(title: builder.title, units: units, partial: builder.partial)
    }

    /// `<!-- … -->` removed in one pass over the bytes (an unclosed comment runs to the end).
    static func removingComments(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count >= 4 else { return text }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        let n = bytes.count
        while i < n {
            if bytes[i] == 0x3C, i + 3 < n, bytes[i + 1] == 0x21, bytes[i + 2] == 0x2D, bytes[i + 3] == 0x2D {
                var j = i + 4
                var closed = false
                while j + 2 < n {
                    if bytes[j] == 0x2D, bytes[j + 1] == 0x2D, bytes[j + 2] == 0x3E { closed = true; break }
                    j += 1
                }
                if !closed { break }
                i = j + 3
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// `![alt](url)` → alt, `[text](url)` → text, `[text][ref]` → text, a leading `>` and `**` `__` backticks and `~~` dropped.
    /// One pass with positions looked up in tables built once, so a line of `[[[[…` costs the same as any other.
    static func stripInline(_ line: String) -> String {
        let chars = Array(line)
        let n = chars.count
        // For each position, the next `]` and the next `)` at or after it.
        var nextBracket = [Int](repeating: n, count: n + 1)
        var nextParen = [Int](repeating: n, count: n + 1)
        if n > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                nextBracket[i] = chars[i] == "]" ? i : nextBracket[i + 1]
                nextParen[i] = chars[i] == ")" ? i : nextParen[i + 1]
            }
        }
        var out = ""
        out.reserveCapacity(n)
        var i = 0
        while i < n {
            let isImage = chars[i] == "!" && i + 1 < n && chars[i + 1] == "["
            if chars[i] == "[" || isImage {
                let open = isImage ? i + 1 : i
                let close = nextBracket[open + 1]
                if close < n, close + 1 < n, isImage || close > open + 1 {
                    let after = chars[close + 1]
                    if after == "(", nextParen[close + 2] < n {
                        out.append(contentsOf: chars[(open + 1)..<close])
                        i = nextParen[close + 2] + 1
                        continue
                    }
                    if after == "[", !isImage, nextBracket[close + 2] < n {
                        out.append(contentsOf: chars[(open + 1)..<close])
                        i = nextBracket[close + 2] + 1
                        continue
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        // A leading block quote mark.
        var result = Substring(out)
        let lead = result.drop { $0 == " " || $0 == "\t" }
        if lead.first == ">" {
            result = lead.dropFirst()
            if result.first == " " { result = result.dropFirst() }
        }
        var cleaned = String(result)
        for mark in ["**", "__", "`", "~~"] { cleaned = cleaned.replacingOccurrences(of: mark, with: "") }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: CSV and TSV

    /// A minimal RFC 4180 reader: quoted fields, doubled quotes, `\n`, `\r\n` and `\r`. Stops at the row and column limits.
    /// `spans` holds, for each kept row, the physical lines of the file it covers (a quoted field can span several).
    static func parseDelimited(_ text: String, delimiter: Character, maxRows: Int, maxColumns: Int,
                               clock: ExtractionClock? = nil) throws -> (rows: [[String]], spans: [ClosedRange<Int>], partial: Bool) {
        var rows: [[String]] = []
        var spans: [ClosedRange<Int>] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var partial = false
        var line = 1
        var rowStart = 1
        var steps = 0
        var characters = text.makeIterator()
        var pending: Character? = characters.next()
        func endField() { if row.count < maxColumns { row.append(field) }; field = "" }
        func endRow() {
            endField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                rows.append(row)
                spans.append(rowStart...max(rowStart, line))
            }
            row = []
        }
        while let ch = pending {
            pending = characters.next()
            steps += 1
            if steps % 65_536 == 0 { try clock?.check() }
            if quoted {
                if ch == "\"" {
                    if pending == "\"" { field.append("\""); pending = characters.next() } else { quoted = false }
                } else {
                    if ch == "\n" || ch == "\r" || ch == "\r\n" { line += 1 }
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"" where field.isEmpty: quoted = true
            case delimiter: endField()
            case "\n", "\r\n", "\r":
                endRow()
                line += 1
                rowStart = line
            default: field.append(ch)
            }
            if rows.count > maxRows { partial = true; break }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return (rows, spans, partial)
    }

    static func table(_ text: String, delimiter: Character, name: String,
                      clock: ExtractionClock = ExtractionClock(seconds: DocumentLimits.textExtractionSeconds)) throws -> ExtractedDocument {
        var delimiter = delimiter
        if delimiter == ",", let first = text.split(separator: "\n", maxSplits: 1).first,
           first.filter({ $0 == ";" }).count > first.filter({ $0 == "," }).count { delimiter = ";" }
        let parsed = try parseDelimited(TextSanitizer.clean(text), delimiter: delimiter, maxRows: DocumentLimits.maxRowsPerSheet + 1,
                                        maxColumns: DocumentLimits.maxColumns, clock: clock)
        guard let headerRow = parsed.rows.first else { throw DocumentExtractionError(.noText) }
        let header = headerRow.map { TextSanitizer.oneLine($0, limit: 60) }
        let columns = header.joined(separator: " | ")
        var units: [DocumentUnit] = []
        var lines: [String] = []
        var first = 0, last = 0
        var partial = parsed.partial
        var characters = 0
        func flush() {
            guard !lines.isEmpty else { return }
            units.append(DocumentUnit(locator: .sheet(name: name, firstRow: first, lastRow: last), text: lines.joined(separator: "\n"), columns: columns))
            characters += lines.reduce(0) { $0 + $1.count }
            lines = []
        }
        for (offset, row) in parsed.rows.enumerated().dropFirst() {
            if offset % 256 == 0 { try clock.check() }
            if offset > DocumentLimits.maxRowsPerSheet { partial = true; break }
            let parts = row.enumerated().compactMap { index, value -> String? in
                let clean = TextSanitizer.oneLine(value, limit: 400)
                guard !clean.isEmpty else { return nil }
                let label = index < header.count && !header[index].isEmpty ? header[index] : XLSXReader.letters(index + 1)
                return "\(label): \(clean)"
            }
            guard !parts.isEmpty else { continue }
            if lines.isEmpty { first = parsed.spans[offset].lowerBound }
            lines.append(parts.joined(separator: "; "))
            last = parsed.spans[offset].upperBound
            if lines.count >= XLSXReader.unitRows || lines.joined(separator: "\n").count >= XLSXReader.unitCharacters { flush() }
            if characters > DocumentLimits.maxCharactersPerFile { partial = true; break }
        }
        flush()
        guard !units.isEmpty else { throw DocumentExtractionError(.noText) }
        return ExtractedDocument(units: units, partial: partial)
    }

    // MARK: Attributed-string formats

    /// RTF and the old Word format, through the system's readers (no WebKit, no network).
    static func attributed(_ url: URL, type: NSAttributedString.DocumentType,
                           clock: ExtractionClock = ExtractionClock(seconds: DocumentLimits.textExtractionSeconds)) throws -> ExtractedDocument {
        let string: NSAttributedString
        do {
            string = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw DocumentExtractionError(.unreadable)
        }
        try clock.check()
        return try plain(string.string, clock: clock)
    }
}
