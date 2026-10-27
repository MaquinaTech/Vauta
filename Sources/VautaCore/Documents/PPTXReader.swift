// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// PowerPoint (`.pptx`, `.ppsx`): one unit per slide, in the order of the presentation, with the speaker notes
/// appended as "Notes: …". Slides with nothing to read are left out.
enum PPTXReader {
    static func read(_ zip: SafeZip, clock: ExtractionClock) throws -> ExtractedDocument {
        guard let presentation = try zip.read("ppt/presentation.xml", maxBytes: 8 << 20) else { throw DocumentExtractionError(.unreadable) }
        let rels = try OOXML.relationships(of: "ppt/presentation.xml", in: zip, limits: clock.xmlLimits)
        let byID = Dictionary(rels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        try SafeXML.parse(presentation, limits: clock.xmlLimits, start: { name, attrs in
            if name == "sldId", let rid = attrs.prefixed("id"), let path = byID[rid]?.path { order.append(path) }
        })
        var units: [DocumentUnit] = []
        var partial = false
        var characters = 0
        for (index, slidePath) in order.enumerated() {
            try clock.check()
            if index >= DocumentLimits.maxSlides { partial = true; break }
            guard let data = try zip.read(slidePath, maxBytes: 16 << 20) else { continue }
            var text = slideText(data, clock: clock)
            let slideRels = try OOXML.relationships(of: slidePath, in: zip, limits: clock.xmlLimits)
            if let notes = slideRels.first(where: { $0.type.hasSuffix("/notesSlide") }),
               let notesData = try zip.read(notes.path, maxBytes: 8 << 20) {
                let spoken = slideText(notesData, clock: clock).split(separator: "\n").filter { line in
                    // The slide number placeholder of a notes page is only digits.
                    !line.allSatisfy(\.isNumber)
                }.joined(separator: "\n")
                if !spoken.isEmpty { text += (text.isEmpty ? "" : "\n") + "Notes: " + spoken }
            }
            text = TextSanitizer.tidy(text)
            guard !text.isEmpty else { continue }
            if characters + text.count > DocumentLimits.maxCharactersPerFile { partial = true; break }
            characters += text.count
            units.append(DocumentUnit(locator: .slide(index + 1), text: text))
        }
        guard !units.isEmpty else { throw DocumentExtractionError(.noText) }
        return ExtractedDocument(title: OOXML.title(in: zip), units: units, partial: partial)
    }

    /// The text of a slide or notes page: one line per paragraph.
    private static func slideText(_ data: Data, clock: ExtractionClock) -> String {
        var out = ""
        var line = ""
        var inText = false
        try? SafeXML.parse(data, limits: clock.xmlLimits, start: { name, _ in
            if name == "t" { inText = true }
            if name == "br" { line += " " }
        }, end: { name in
            if name == "t" { inText = false }
            if name == "p" {
                let clean = TextSanitizer.clean(line).trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty { out += clean + "\n" }
                line = ""
            }
        }, text: { if inText { line += $0 } })
        return out
    }
}
