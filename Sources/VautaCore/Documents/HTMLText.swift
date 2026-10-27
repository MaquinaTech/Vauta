// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// HTML as text, with a tag stripper of our own. Never `NSAttributedString(.html)`: it loads WebKit, needs the main
/// thread and can fetch remote resources. Nothing here loads, runs or follows anything.
///
/// Dropped with everything inside them: `script`, `style`, `head` (except `title`), `svg`, `template`, `noscript`,
/// `iframe`, `object`, `canvas`, and any element with `hidden`, `aria-hidden="true"` or `display:none` / `visibility:hidden`
/// in its inline style (a way to hide instructions from a reader). Block tags become line breaks, `h1`...`h6` headings.
enum HTMLText {
    private static let skipped: Set<String> = ["script", "style", "head", "svg", "template", "noscript", "iframe", "object", "canvas", "math", "select", "option"]
    private static let voids: Set<String> = ["br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr", "param"]
    private static let blocks: Set<String> = ["p", "div", "br", "li", "tr", "section", "article", "header", "footer", "blockquote", "pre", "ul", "ol",
                                              "table", "hr", "dd", "dt", "dl", "form", "fieldset", "figure", "figcaption", "main", "nav", "aside",
                                              "address", "details", "summary", "tbody", "thead", "tfoot", "caption", "body", "html"]

    static func extract(_ html: String, clock: ExtractionClock) throws -> ExtractedDocument {
        let bytes = Array(html.utf8)
        var builder = RunningTextBuilder()
        var line = ""
        var stack: [String] = []
        var skipBase: Int?
        var heading: (level: Int, text: String)?
        var titleText = "", inTitle = false
        var preDepth = 0
        var i = 0
        let n = bytes.count

        func flushLine() {
            let clean = TextSanitizer.clean(line)
            line = ""
            if !clean.isEmpty { builder.add(line: clean) }
        }
        func appendText(_ text: String) {
            guard skipBase == nil || inTitle else { return }
            if inTitle { titleText += text; return }
            if var h = heading { h.text += text; heading = h; return }
            if preDepth > 0 {
                line += text
                return
            }
            // Runs of whitespace are one space, as a browser shows them.
            var previousSpace = line.last == " " || line.isEmpty
            for ch in text {
                if ch.isWhitespace {
                    if !previousSpace { line.append(" ") }
                    previousSpace = true
                } else {
                    line.append(ch)
                    previousSpace = false
                }
            }
        }
        func breakLine() {
            guard skipBase == nil else { return }
            if heading == nil { flushLine() }
        }

        var tick = 0
        while i < n {
            tick += 1
            if tick & 0xFFFF == 0 { try clock.check() }
            if bytes[i] != UInt8(ascii: "<") {
                var j = i
                while j < n, bytes[j] != UInt8(ascii: "<") { j += 1 }
                appendText(decodeEntities(String(decoding: bytes[i..<j], as: UTF8.self)))
                i = j
                continue
            }
            // A comment, a CDATA section or a processing instruction: dropped.
            if matches(bytes, i, "<!--") {
                i = find(bytes, "-->", from: i + 4).map { $0 + 3 } ?? n
                continue
            }
            if matches(bytes, i, "<![CDATA[") {
                let end = find(bytes, "]]>", from: i + 9) ?? n
                appendText(String(decoding: bytes[(i + 9)..<min(end, n)], as: UTF8.self))
                i = min(n, end + 3)
                continue
            }
            if i + 1 < n, bytes[i + 1] == UInt8(ascii: "!") || bytes[i + 1] == UInt8(ascii: "?") {
                i = find(bytes, ">", from: i + 2).map { $0 + 1 } ?? n
                continue
            }
            let closing = i + 1 < n && bytes[i + 1] == UInt8(ascii: "/")
            let nameStart = i + (closing ? 2 : 1)
            guard nameStart < n, isLetter(bytes[nameStart]) else {
                appendText("<")
                i += 1
                continue
            }
            // The tag: up to the `>` that is not inside quotes.
            var j = nameStart
            var quote: UInt8?
            while j < n {
                let b = bytes[j]
                if let q = quote { if b == q { quote = nil } } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") { quote = b } else if b == UInt8(ascii: ">") { break }
                j += 1
            }
            let tag = String(decoding: bytes[nameStart..<min(j, n)], as: UTF8.self)
            i = min(n, j + 1)
            let name = String(tag.prefix { !$0.isWhitespace && $0 != "/" }).lowercased()
            let selfClosing = tag.hasSuffix("/")
            if closing {
                if name == "title" { inTitle = false }
                if let index = stack.lastIndex(of: name) {
                    stack.removeSubrange(index...)
                    if let base = skipBase, stack.count < base { skipBase = nil }
                }
                if name == "pre" { preDepth = max(0, preDepth - 1); if preDepth == 0 { flushLine() } }
                if name.count == 2, name.hasPrefix("h"), let level = Int(name.dropFirst()), (1...6).contains(level), let h = heading, h.level == level {
                    heading = nil
                    builder.heading(level: level, text: h.text)
                } else if Self.blocks.contains(name) {
                    breakLine()
                } else if name == "td" || name == "th" {
                    appendText(" | ")
                }
                continue
            }
            if name == "title" {
                // Only the page's own title (in the head): not one inside hidden content, an SVG or the body.
                let inHead = stack.firstIndex(of: "head").map { skipBase == $0 + 1 } ?? false
                if skipBase == nil || inHead, !stack.contains("svg"), !stack.contains("body") { inTitle = true }
                continue
            }
            let attrs = skipBase == nil ? attributes(of: tag) : [:]
            if Self.voids.contains(name) || selfClosing {
                if name == "br" { breakLine() }
                continue
            }
            stack.append(name)
            if skipBase == nil, Self.skipped.contains(name) || isHidden(attrs) { skipBase = stack.count }
            guard skipBase == nil else { continue }
            if name == "pre" { flushLine(); preDepth += 1 }
            if name.count == 2, name.hasPrefix("h"), let level = Int(name.dropFirst()), (1...6).contains(level) {
                flushLine()
                heading = (level, "")
            } else if Self.blocks.contains(name) {
                breakLine()
            }
        }
        flushLine()
        let title = TextSanitizer.oneLine(decodeEntities(titleText), limit: 160)
        let units = builder.finish()
        guard !units.isEmpty else { throw DocumentExtractionError(.noText) }
        return ExtractedDocument(title: title.isEmpty ? builder.title : title, units: units, partial: builder.partial)
    }

    // MARK: Tags

    private static func isLetter(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }

    private static func matches(_ bytes: [UInt8], _ at: Int, _ literal: String) -> Bool {
        let lit = Array(literal.utf8)
        guard at + lit.count <= bytes.count else { return false }
        for k in 0..<lit.count where bytes[at + k] != lit[k] { return false }
        return true
    }

    private static func find(_ bytes: [UInt8], _ literal: String, from: Int) -> Int? {
        let lit = Array(literal.utf8)
        guard !lit.isEmpty, bytes.count >= lit.count, from <= bytes.count - lit.count else { return nil }
        var i = from
        while i <= bytes.count - lit.count {
            if bytes[i] == lit[0], matches(bytes, i, literal) { return i }
            i += 1
        }
        return nil
    }

    /// The attributes that matter (`hidden`, `aria-hidden`, `style`), lowercased names.
    private static func attributes(of tag: String) -> [String: String] {
        var out: [String: String] = [:]
        let chars = Array(tag)
        var i = 0
        while i < chars.count, !chars[i].isWhitespace { i += 1 }
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "/" { i += 1 }
            var name = ""
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "=", chars[i] != "/" { name.append(chars[i]); i += 1 }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let q = chars[i]
                    i += 1
                    while i < chars.count, chars[i] != q { value.append(chars[i]); i += 1 }
                    i += 1
                } else {
                    while i < chars.count, !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
                }
            }
            if !name.isEmpty { out[name.lowercased()] = value }
        }
        return out
    }

    private static func isHidden(_ attrs: [String: String]) -> Bool {
        if attrs["hidden"] != nil { return true }
        if attrs["aria-hidden"]?.lowercased() == "true" { return true }
        let style = (attrs["style"] ?? "").lowercased().filter { !$0.isWhitespace }
        return style.contains("display:none") || style.contains("visibility:hidden") || style.contains("font-size:0")
    }

    // MARK: Entities

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "bull": "•", "middot": "·", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "deg": "°", "plusmn": "±",
        "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼", "frac34": "¾", "iexcl": "¡", "iquest": "¿", "szlig": "ß",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç",
        "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï",
        "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù",
        "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "yuml": "ÿ", "Agrave": "À", "Aacute": "Á", "Acirc": "Â",
        "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê",
        "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó",
        "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "ne": "≠", "le": "≤", "ge": "≥", "infin": "∞",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            guard ch == "&", let semicolon = text[i...].prefix(12).firstIndex(of: ";") else { out.append(ch); i = text.index(after: i); continue }
            let body = String(text[text.index(after: i)..<semicolon])
            var replacement: String?
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let value, let scalar = Unicode.Scalar(value) { replacement = String(Character(scalar)) }
            } else {
                replacement = named[body]
            }
            if let replacement {
                out += replacement
                i = text.index(after: semicolon)
            } else {
                out.append(ch)
                i = text.index(after: i)
            }
        }
        return out
    }
}
