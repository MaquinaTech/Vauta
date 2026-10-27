// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Excel (`.xlsx`, `.xltx`): each visible sheet's first non-empty row is its header, and every later row becomes a line
/// "Header: value; Header: value", so a row can be found and cited on its own. Formulas are never evaluated (the cached
/// value is read); dates stay the raw serial number in this version. At most 20 sheets, 5,000 rows and 50 columns each.
enum XLSXReader {
    /// About how many characters of rows go in one unit (one cited passage).
    static let unitCharacters = 700
    static let unitRows = 25

    static func read(_ zip: SafeZip, clock: ExtractionClock) throws -> ExtractedDocument {
        guard let workbook = try zip.read("xl/workbook.xml", maxBytes: 8 << 20) else { throw DocumentExtractionError(.unreadable) }
        let rels = try OOXML.relationships(of: "xl/workbook.xml", in: zip, limits: clock.xmlLimits)
        let byID = Dictionary(rels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sheets: [(name: String, path: String)] = []
        try SafeXML.parse(workbook, limits: clock.xmlLimits, start: { name, attrs in
            guard name == "sheet", let sheetName = attrs["name"], let rid = attrs.prefixed("id"), let path = byID[rid]?.path else { return }
            // Hidden sheets are not the user's to share: they are skipped.
            if let state = attrs["state"], state != "visible" { return }
            sheets.append((TextSanitizer.oneLine(sheetName, limit: 80), path))
        })
        let shared = try sharedStrings(zip, clock: clock)
        var units: [DocumentUnit] = []
        var partial = false
        var characters = 0
        for (index, sheet) in sheets.enumerated() {
            try clock.check()
            if index >= DocumentLimits.maxSheets { partial = true; break }
            guard let data = try zip.read(sheet.path, maxBytes: 64 << 20) else { continue }
            let result = try readSheet(data, name: sheet.name, shared: shared, clock: clock, budget: DocumentLimits.maxCharactersPerFile - characters)
            units += result.units
            characters += result.units.reduce(0) { $0 + $1.text.count }
            if result.partial { partial = true }
            if characters >= DocumentLimits.maxCharactersPerFile { partial = true; break }
        }
        guard !units.isEmpty else { throw DocumentExtractionError(.noText) }
        return ExtractedDocument(title: OOXML.title(in: zip), units: units, partial: partial)
    }

    private static func sharedStrings(_ zip: SafeZip, clock: ExtractionClock) throws -> [String] {
        guard let data = try zip.read("xl/sharedStrings.xml", maxBytes: 64 << 20) else { return [] }
        var out: [String] = []
        var current = ""
        var inText = false
        var phonetic = 0
        try SafeXML.parse(data, limits: clock.xmlLimits, start: { name, _ in
            switch name {
            case "si": current = ""
            case "rPh": phonetic += 1
            case "t": inText = true
            default: break
            }
        }, end: { name in
            switch name {
            case "si": out.append(TextSanitizer.clean(current)); current = ""
            case "rPh": phonetic = max(0, phonetic - 1)
            case "t": inText = false
            default: break
            }
        }, text: { if inText, phonetic == 0 { current += $0 } })
        return out
    }

    /// "B12" → column 2 (1-based).
    static func column(of reference: String) -> Int {
        var n = 0
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 || (scalar.value >= 97 && scalar.value <= 122) else { break }
            n = n * 26 + Int((scalar.value & 0x1F))
            if n > 20_000 { return 0 }
        }
        return n
    }

    static func letters(_ column: Int) -> String {
        var n = column, out = ""
        while n > 0 {
            let r = (n - 1) % 26
            out = String(UnicodeScalar(UInt8(65 + r))) + out
            n = (n - 1) / 26
        }
        return out
    }

    private static func readSheet(_ data: Data, name: String, shared: [String], clock: ExtractionClock,
                                  budget: Int) throws -> (units: [DocumentUnit], partial: Bool) {
        var header: [Int: String] = [:]
        var headerRow: Int?
        var units: [DocumentUnit] = []
        var lines: [String] = []
        var firstRow = 0, lastRow = 0
        var characters = 0
        var rowCount = 0
        var partial = false
        // The cells of the row being read, by column.
        var cells: [Int: String] = [:]
        var rowNumber = 0
        var cellColumn = 0, cellType = "", nextColumn = 1
        var inValue = false, inInline = false, inInlineText = false
        var valueText = "", inlineText = ""
        var stopped = false

        func flush() {
            guard !lines.isEmpty else { return }
            let columns = header.keys.sorted().map { header[$0] ?? "" }.joined(separator: " | ")
            units.append(DocumentUnit(locator: .sheet(name: name, firstRow: firstRow, lastRow: lastRow), text: lines.joined(separator: "\n"),
                                      columns: columns.isEmpty ? nil : columns))
            characters += lines.reduce(0) { $0 + $1.count }
            lines = []
        }

        func finishRow() {
            defer { cells = [:] }
            guard !cells.isEmpty, !stopped else { return }
            if headerRow == nil {
                headerRow = rowNumber
                for (col, value) in cells where col <= DocumentLimits.maxColumns {
                    header[col] = TextSanitizer.oneLine(value, limit: 60)
                }
                return
            }
            rowCount += 1
            if rowCount > DocumentLimits.maxRowsPerSheet { partial = true; stopped = true; return }
            let parts = cells.keys.sorted().filter { $0 <= DocumentLimits.maxColumns }.compactMap { col -> String? in
                let value = TextSanitizer.oneLine(cells[col] ?? "", limit: 400)
                guard !value.isEmpty else { return nil }
                let label = header[col].flatMap { $0.isEmpty ? nil : $0 } ?? letters(col)
                return "\(label): \(value)"
            }
            guard !parts.isEmpty else { return }
            let line = parts.joined(separator: "; ")
            if lines.isEmpty { firstRow = rowNumber }
            lines.append(line)
            lastRow = rowNumber
            if lines.joined(separator: "\n").count >= unitCharacters || lines.count >= unitRows { flush() }
            if characters > budget { partial = true; stopped = true }
        }

        try SafeXML.parse(data, limits: clock.xmlLimits, start: { element, attrs in
            guard !stopped else { return }
            switch element {
            case "row":
                rowNumber = attrs["r"].flatMap(Int.init) ?? (rowNumber + 1)
                nextColumn = 1
                cells = [:]
            case "c":
                cellColumn = attrs["r"].map(column(of:)).flatMap { $0 > 0 ? $0 : nil } ?? nextColumn
                nextColumn = cellColumn + 1
                cellType = attrs["t"] ?? "n"
                valueText = ""
                inlineText = ""
            case "v": inValue = true
            case "is": inInline = true
            case "t": if inInline { inInlineText = true }
            default: break
            }
        }, end: { element in
            switch element {
            case "v": inValue = false
            case "t": inInlineText = false
            case "is": inInline = false
            case "c":
                guard !stopped, cellColumn <= DocumentLimits.maxColumns else { return }
                var value: String?
                switch cellType {
                case "s": if let i = Int(valueText.trimmingCharacters(in: .whitespaces)), shared.indices.contains(i) { value = shared[i] }
                case "inlineStr": value = inlineText
                case "b": value = valueText.trimmingCharacters(in: .whitespaces) == "1" ? "TRUE" : "FALSE"
                case "e": value = nil
                default: value = valueText
                }
                if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty { cells[cellColumn] = value }
            case "row": finishRow()
            default: break
            }
        }, text: { text in
            if inValue { valueText += text }
            if inInlineText { inlineText += text }
        })
        flush()
        return (units, partial)
    }
}
