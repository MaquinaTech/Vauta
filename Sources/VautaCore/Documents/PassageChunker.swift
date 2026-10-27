// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
internal import NaturalLanguage

/// A passage ready to be stored: the text that is searched, sent to the model and shown to the person.
public struct PassageDraft: Sendable, Equatable {
    /// Stable across re-indexing and renames: a hash of the locator and the normalized text, never the path.
    public let key: String
    /// The order inside the file.
    public let ordinal: Int
    public let locator: DocumentLocator
    /// The context line (title, heading path or sheet and columns) followed by the passage.
    public let text: String
    public let ocr: Bool

    public init(key: String, ordinal: Int, locator: DocumentLocator, text: String, ocr: Bool) {
        self.key = key
        self.ordinal = ordinal
        self.locator = locator
        self.text = text
        self.ocr = ocr
    }
}

/// Splits what an extractor read into passages: about 800 characters (400 where most of the text is Han, Kana or Hangul,
/// which cost about a token each), never more than one and a half times that, never across a page, slide or sheet block,
/// cut at sentence ends, with one sentence of overlap, and each starting with a line that says where it comes from.
public enum PassageChunker {
    public static let targetCharacters = 800
    public static let denseTargetCharacters = 400

    public static func chunk(_ document: ExtractedDocument, fileName: String) -> [PassageDraft] {
        let base = (fileName as NSString).deletingPathExtension
        let name = TextSanitizer.oneLine(document.title ?? base, limit: 100)
        var out: [PassageDraft] = []
        var seen = Set<String>()
        for (index, unit) in document.units.enumerated() {
            let dense = isDense(unit.text)
            let target = dense ? denseTargetCharacters : targetCharacters
            let pieces = split(unit.text, target: target, maximum: target * 3 / 2)
            let groups = pack(pieces, target: target, maximum: target * 3 / 2)
            for (part, group) in groups.enumerated() {
                let locator = placed(unit, firstLine: group.firstLine)
                let text = header(for: unit, name: name) + "\n" + group.text
                let key = key(locator, text)
                guard seen.insert(key).inserted else { continue }
                let base: Int
                switch unit.locator {
                case .page(let n), .slide(let n): base = n * 1000
                default: base = index * 1000
                }
                out.append(PassageDraft(key: key, ordinal: base + min(part, 999), locator: locator, text: text, ocr: unit.ocr))
            }
        }
        return out
    }

    /// The context line.
    static func header(for unit: DocumentUnit, name: String) -> String {
        switch unit.locator {
        case .page(let n): return "\(name) (page \(n))"
        case .slide(let n): return "\(name) (slide \(n))"
        case .sheet(let sheet, let a, let b):
            let label = sheet.isEmpty ? "Rows \(a)–\(b)" : "Sheet \"\(sheet)\", rows \(a)–\(b)"
            return unit.columns.map { "\(name) — \(label) — columns: \(TextSanitizer.oneLine($0, limit: 200))" } ?? "\(name) — \(label)"
        case .section(let path, _): return ([name] + path.map { TextSanitizer.oneLine($0, limit: 80) }).joined(separator: " › ")
        case .image: return name
        }
    }

    /// The locator of a passage that starts `firstLine` lines into its unit (running text counts paragraphs).
    private static func placed(_ unit: DocumentUnit, firstLine: Int) -> DocumentLocator {
        if case .section(let path, _) = unit.locator { return .section(path: path, block: unit.firstBlock + firstLine) }
        return unit.locator
    }

    static func key(_ locator: DocumentLocator, _ text: String) -> String { key(locatorJSON: locator.json, text) }

    static func key(locatorJSON: String, _ text: String) -> String {
        let digest = SHA256.hash(data: Data((locatorJSON + "\u{1F}" + TextKeys.norm(text)).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// More than 30% of the letters are Han, Kana or Hangul.
    static func isDense(_ text: String) -> Bool {
        var dense = 0, letters = 0
        for scalar in text.unicodeScalars.prefix(4000) where scalar.properties.isAlphabetic {
            letters += 1
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0x1100...0x11FF, 0xF900...0xFAFF, 0x20000...0x2FFFF: dense += 1
            default: break
            }
        }
        return letters > 0 && dense * 10 > letters * 3
    }

    // MARK: Splitting and packing

    /// A line of the unit, or a sentence of a long line.
    struct Piece {
        var text: String
        var line: Int
        /// The piece starts a line (it is not the continuation of a sentence split).
        var startsLine: Bool
    }

    static func split(_ text: String, target: Int, maximum: Int) -> [Piece] {
        var pieces: [Piece] = []
        for (line, raw) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let lineText = String(raw)
            if lineText.count <= target {
                pieces.append(Piece(text: lineText, line: line, startsLine: true))
                continue
            }
            var first = true
            for sentence in sentences(of: lineText) {
                for chunk in hardCut(sentence, maximum: maximum) {
                    pieces.append(Piece(text: chunk, line: line, startsLine: first))
                    first = false
                }
            }
        }
        return pieces
    }

    static func sentences(of text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { out.append(sentence) }
            return true
        }
        return out.isEmpty ? [text] : out
    }

    /// A sentence longer than `maximum` is cut at a space near the limit, or at the limit.
    static func hardCut(_ sentence: String, maximum: Int) -> [String] {
        // Walks with indices: counting what is left at every step would make one very long line quadratic.
        guard let probe = sentence.index(sentence.startIndex, offsetBy: maximum, limitedBy: sentence.endIndex), probe != sentence.endIndex else { return [sentence] }
        var out: [String] = []
        var start = sentence.startIndex
        while let limit = sentence.index(start, offsetBy: maximum, limitedBy: sentence.endIndex), limit != sentence.endIndex {
            let window = sentence[start..<limit]
            var cut = limit
            if let space = window.lastIndex(where: { $0 == " " }), window.distance(from: window.startIndex, to: space) > maximum / 2 { cut = space }
            out.append(sentence[start..<cut].trimmingCharacters(in: .whitespaces))
            start = cut
            while start < sentence.endIndex, sentence[start] == " " { start = sentence.index(after: start) }
        }
        if start < sentence.endIndex { out.append(String(sentence[start...])) }
        return out.filter { !$0.isEmpty }
    }

    struct Group {
        var text: String
        var firstLine: Int
    }

    static func pack(_ pieces: [Piece], target: Int, maximum: Int) -> [Group] {
        var groups: [Group] = []
        var current: [Piece] = []
        var size = 0
        func join(_ items: [Piece]) -> String {
            var out = ""
            for (i, piece) in items.enumerated() {
                if i > 0 { out += piece.startsLine ? "\n" : " " }
                out += piece.text
            }
            return out
        }
        func flush() {
            guard !current.isEmpty else { return }
            groups.append(Group(text: join(current), firstLine: current[0].line))
        }
        for piece in pieces {
            if size > 0, size + piece.text.count + 1 > target, size >= target / 2 || size + piece.text.count + 1 > maximum {
                flush()
                // One piece of overlap, when it is a sentence and short, so a fact on the edge is in both passages.
                // Never when the overlap and the piece together would pass the maximum.
                if let last = current.last, current.count > 1, last.text.count <= target / 3, last.text.count + piece.text.count + 2 <= maximum {
                    current = [last]
                    size = last.text.count
                } else {
                    current = []
                    size = 0
                }
            }
            current.append(piece)
            size += piece.text.count + 1
        }
        // The tail always holds a piece the groups before it do not (an overlap is only ever followed by a new piece).
        flush()
        return groups
    }
}
