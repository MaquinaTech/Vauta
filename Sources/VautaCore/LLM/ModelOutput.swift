// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Cleans up what a model returns before Swift validates it: reasoning
/// blocks, code fences and text around the JSON object.
enum ModelOutput {
    /// Removes a reasoning block at the start of the answer: `<think>…</think>`,
    /// `<thinking>…</thinking>`, `[THINK]…[/THINK]`, the Harmony analysis
    /// channel, or reasoning whose opening tag was part of the chat template
    /// (text up to a lone `</think>`). A block that never closes means the
    /// answer was cut off during reasoning, so nothing is left.
    ///
    /// Only *leading* reasoning is removed: an answer that merely mentions
    /// `<think>` later on is returned unchanged.
    static func strippingReasoning(_ text: String) -> String {
        var out = Substring(text)
        if let final = harmonyFinal(out) { return final.trimmingCharacters(in: .whitespacesAndNewlines) }
        while true {
            let trimmed = out.drop(while: \.isWhitespace)
            guard let (open, close) = pairs.first(where: { trimmed.hasPrefix($0.open) }) else { break }
            let body = trimmed.dropFirst(open.count)
            guard let end = body.range(of: close) else { return "" }
            out = body[end.upperBound...]
        }
        // Templates that open the block themselves (Qwen3, DeepSeek-R1): the
        // answer starts with reasoning and a lone closing tag. An answer that
        // starts as JSON is never cut.
        let trimmed = out.drop(while: \.isWhitespace)
        if !trimmed.hasPrefix("{"), let end = trimmed.range(of: "</think>"),
           !trimmed[..<end.lowerBound].contains("<think>") {
            out = trimmed[end.upperBound...]
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let pairs: [(open: String, close: String)] = [
        ("<think>", "</think>"), ("<thinking>", "</thinking>"), ("[THINK]", "[/THINK]"),
    ]

    /// Harmony (gpt-oss) output that still carries its channel markers, with
    /// or without the special tokens: the text of the final channel, or ""
    /// when only the analysis channel arrived. nil when it is not Harmony.
    private static func harmonyFinal(_ text: Substring) -> String? {
        let trimmed = text.drop(while: \.isWhitespace)
        if trimmed.hasPrefix("<|channel|>") || trimmed.hasPrefix("<|start|>") {
            guard let marker = trimmed.range(of: "<|channel|>final<|message|>") else { return "" }
            var final = trimmed[marker.upperBound...]
            for end in ["<|return|>", "<|end|>"] {
                if let r = final.range(of: end) { final = final[..<r.lowerBound] }
            }
            return String(final)
        }
        // Special tokens removed by the server: "analysis…assistantfinal…".
        if trimmed.hasPrefix("analysis"), let marker = trimmed.range(of: "assistantfinal") {
            return String(trimmed[marker.upperBound...])
        }
        return nil
    }

    /// Whether an answer stops inside its JSON object (an open string or
    /// unclosed braces): the answer was cut at the token limit by a provider
    /// that does not say why it stopped (Apple's on-device model).
    static func endsInsideJSON(_ text: String) -> Bool {
        guard let start = text.firstIndex(of: "{") else { return false }
        var depth = 0, inString = false, escaped = false
        for ch in text[start...] {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return false }
            default: break
            }
        }
        return true
    }

    /// A JSON object that was cut off (the token limit) closed at its last complete element: the text up to the last comma that is
    /// outside a string and inside no more than `maxDepth` brackets, then the brackets that were open there. nil when nothing complete
    /// is left to keep (no comma yet, or the first value is the one that was cut). Whatever the model wrote before the cut is kept
    /// word for word; the rest is dropped, never completed.
    static func closingTruncatedJSON(_ text: String, maxDepth: Int = 2) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var stack: [Character] = []
        var inString = false, escaped = false
        var best: (end: String.Index, closers: [Character])?
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": stack.append("}")
                case "[": stack.append("]")
                case "}", "]":
                    guard stack.popLast() == ch else { return nil }
                    if stack.isEmpty { return String(text[start...index]) }   // it was complete after all
                case ",": if stack.count <= maxDepth { best = (index, stack) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        guard let best else { return nil }
        return String(text[start..<best.end]) + String(best.closers.reversed())
    }

    /// The JSON object in an answer (tolerates code fences and text around it).
    static func decodeObject<T: Decodable>(_ type: T.Type, from content: String) throws -> T {
        let text = strippingReasoning(content)
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else {
            throw LLMError.invalidResponse("no JSON object")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text[a...b].utf8))
        } catch {
            throw LLMError.invalidResponse("invalid JSON")
        }
    }
}

// MARK: Lenient decoding

/// Any JSON key: model answers are read by name, accepting the English keys
/// and the legacy Spanish ones.
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// The first of `keys` that is present and decodes; nil otherwise. A
    /// value of the wrong type counts as missing (the item is still read).
    func value<T: Decodable>(_ type: T.Type, _ keys: String...) -> T? {
        for key in keys {
            if let v = try? decodeIfPresent(T.self, forKey: AnyKey(key)) { return v }
        }
        return nil
    }

    /// A text value; numbers are accepted as text, written the same in every locale (`plainText`).
    func text(_ keys: String...) -> String? {
        for key in keys {
            if let s = try? decodeIfPresent(String.self, forKey: AnyKey(key)) { return s }
            if let n = try? decodeIfPresent(Double.self, forKey: AnyKey(key)) { return n.plainText }
        }
        return nil
    }

    /// A true/false value written as a boolean, `"true"`/`"false"`, `"yes"`/`"no"` or 0/1; nil when absent or anything else.
    func flag(_ keys: String...) -> Bool? {
        for key in keys {
            if let b = try? decodeIfPresent(Bool.self, forKey: AnyKey(key)) { return b }
            if let s = try? decodeIfPresent(String.self, forKey: AnyKey(key)) {
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true", "yes", "si", "sí": return true
                case "false", "no": return false
                default: break
                }
            }
        }
        return nil
    }

    /// An ID written as a number, as a numeric string or with its prefix ("S12", "E4").
    func id(_ keys: String...) -> Int64? {
        for key in keys {
            if let n = try? decodeIfPresent(Int64.self, forKey: AnyKey(key)) { return n }
            if let s = try? decodeIfPresent(String.self, forKey: AnyKey(key)) { return Self.parseID(s) }
        }
        return nil
    }

    /// A list of IDs (numbers or strings), or a single ID.
    func ids(_ keys: String...) -> [Int64] {
        for key in keys {
            if let list = try? decodeIfPresent([Lossy<FlexibleID>].self, forKey: AnyKey(key)) {
                return list.compactMap { $0.value?.id }
            }
            if let one = try? decodeIfPresent(FlexibleID.self, forKey: AnyKey(key)), let id = one.id { return [id] }
        }
        return []
    }

    /// The decodable elements of a list (an element that does not decode is skipped).
    func list<T: Decodable>(_ type: T.Type, _ keys: String...) -> [T]? {
        for key in keys {
            if let list = try? decodeIfPresent([Lossy<T>].self, forKey: AnyKey(key)) { return list.compactMap(\.value) }
        }
        return nil
    }

    static func parseID(_ s: String) -> Int64? {
        let digits = s.trimmingCharacters(in: .whitespaces).drop { $0 == "S" || $0 == "E" || $0 == "[" || $0 == "s" || $0 == "e" }
        return Int64(digits.prefix { $0.isASCII && $0.isNumber })
    }
}

/// Decodes an element if possible, never failing the enclosing list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// An ID as a number or a string.
struct FlexibleID: Decodable {
    let id: Int64?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int64.self) { id = n }
        else if let s = try? c.decode(String.self) { id = KeyedDecodingContainer<AnyKey>.parseID(s) }
        else { id = nil }
    }
}

extension Double {
    /// A number as the model wrote it, whatever the Mac's region: no grouping, a "." decimal point, a whole number without
    /// ".0" ("2026", "1.5"). `formatted()` would write "2.026" or "1,5" in German.
    var plainText: String {
        if rounded() == self, abs(self) < 9_007_199_254_740_992 { return String(Int64(self)) }
        return String(self)
    }
}
