// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A JSON value whose strings are raw UTF-8 bytes.
///
/// Swift `String` equality is canonical equivalence, and the Gemma vocabulary has 434 groups of distinct tokens that are
/// canonically equivalent (for example U+09DF against U+09AF U+09BC). A `[String: Int]` would merge them, so everything
/// that is keyed by token text is keyed by bytes.
public enum JV: Sendable {
    case str([UInt8])
    case num(Double)
    case arr([JV])
    case obj([(key: [UInt8], value: JV)])
    case lit

    public func get(_ key: String) -> JV? {
        guard case .obj(let o) = self else { return nil }
        let kb = Array(key.utf8)
        return o.first { $0.key == kb }?.value
    }

    public var string: String? {
        if case .str(let b) = self { return String(decoding: b, as: UTF8.self) }
        return nil
    }

    /// A whole number (nil for anything else, including fractions and values that do not fit an `Int`).
    public var int: Int? {
        guard case .num(let d) = self, d.rounded() == d, abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }

    public var array: [JV]? {
        if case .arr(let a) = self { return a }
        return nil
    }
}

public enum ByteJSONError: Error, Equatable, Sendable {
    case syntax(offset: Int)
    case tooDeep
    case trailingBytes
}

/// A minimal, bounds-checked, byte-exact JSON parser for the files this feature reads (a safetensors header, the tensor
/// manifest and the tokenizer). Malformed input throws; it never reads out of bounds.
public struct ByteJSON {
    private let b: UnsafeBufferPointer<UInt8>
    private var i = 0
    static let maxDepth = 64

    public init(_ bytes: UnsafeBufferPointer<UInt8>) { b = bytes }

    /// Parses one value and requires that only whitespace follows.
    public static func parse(_ bytes: UnsafeBufferPointer<UInt8>) throws -> JV {
        var p = ByteJSON(bytes)
        let v = try p.parse(depth: 0)
        p.ws()
        guard p.i == bytes.count else { throw ByteJSONError.trailingBytes }
        return v
    }

    public static func parse(_ data: Data) throws -> JV {
        try data.withUnsafeBytes { try parse($0.bindMemory(to: UInt8.self)) }
    }

    private mutating func ws() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    private func at(_ offset: Int) throws -> UInt8 {
        guard offset < b.count else { throw ByteJSONError.syntax(offset: offset) }
        return b[offset]
    }

    private mutating func parse(depth: Int) throws -> JV {
        guard depth <= Self.maxDepth else { throw ByteJSONError.tooDeep }
        ws()
        switch try at(i) {
        case UInt8(ascii: "{"):
            i += 1
            var items: [(key: [UInt8], value: JV)] = []
            ws()
            if try at(i) == UInt8(ascii: "}") { i += 1; return .obj(items) }
            while true {
                ws()
                let k = try string()
                ws()
                guard try at(i) == UInt8(ascii: ":") else { throw ByteJSONError.syntax(offset: i) }
                i += 1
                items.append((k, try parse(depth: depth + 1)))
                ws()
                let c = try at(i)
                i += 1
                if c == UInt8(ascii: ",") { continue }
                if c == UInt8(ascii: "}") { return .obj(items) }
                throw ByteJSONError.syntax(offset: i - 1)
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [JV] = []
            ws()
            if try at(i) == UInt8(ascii: "]") { i += 1; return .arr(items) }
            while true {
                items.append(try parse(depth: depth + 1))
                ws()
                let c = try at(i)
                i += 1
                if c == UInt8(ascii: ",") { continue }
                if c == UInt8(ascii: "]") { return .arr(items) }
                throw ByteJSONError.syntax(offset: i - 1)
            }
        case UInt8(ascii: "\""):
            return .str(try string())
        default:
            let s = i
            while i < b.count, !(b[i] == UInt8(ascii: ",") || b[i] == UInt8(ascii: "}") || b[i] == UInt8(ascii: "]")
                                 || b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09) { i += 1 }
            guard i > s else { throw ByteJSONError.syntax(offset: i) }
            let t = String(decoding: UnsafeBufferPointer(rebasing: b[s..<i]), as: UTF8.self)
            if let d = Double(t), d.isFinite { return .num(d) }
            guard t == "true" || t == "false" || t == "null" else { throw ByteJSONError.syntax(offset: s) }
            return .lit
        }
    }

    private mutating func string() throws -> [UInt8] {
        guard try at(i) == UInt8(ascii: "\"") else { throw ByteJSONError.syntax(offset: i) }
        i += 1
        var out: [UInt8] = []
        while true {
            let c = try at(i)
            if c == UInt8(ascii: "\"") { i += 1; return out }
            if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
            i += 1
            let e = try at(i)
            i += 1
            switch e {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "u"):
                var cp = try hex4()
                if cp >= 0xD800 && cp < 0xDC00, try at(i) == UInt8(ascii: "\\"), try at(i + 1) == UInt8(ascii: "u") {
                    i += 2
                    let lo = try hex4()
                    guard lo >= 0xDC00 && lo < 0xE000 else { throw ByteJSONError.syntax(offset: i) }
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                }
                guard let sc = Unicode.Scalar(cp) else { throw ByteJSONError.syntax(offset: i) }
                out += Array(String(Character(sc)).utf8)
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
            default: throw ByteJSONError.syntax(offset: i - 1)
            }
        }
    }

    private mutating func hex4() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = try at(i)
            i += 1
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            default: throw ByteJSONError.syntax(offset: i - 1)
            }
            v = v << 4 | d
        }
        return v
    }
}
