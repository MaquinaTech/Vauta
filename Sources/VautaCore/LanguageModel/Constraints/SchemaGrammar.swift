// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A set of byte values, as four 64-bit words.
struct ByteSet: Equatable, Hashable, Sendable {
    var w: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

    static func == (a: ByteSet, b: ByteSet) -> Bool { a.w == b.w }
    func hash(into h: inout Hasher) { h.combine(w.0); h.combine(w.1); h.combine(w.2); h.combine(w.3) }

    @inline(__always) func contains(_ b: UInt8) -> Bool {
        let bit = UInt64(1) << UInt64(b & 63)
        switch b >> 6 {
        case 0: return w.0 & bit != 0
        case 1: return w.1 & bit != 0
        case 2: return w.2 & bit != 0
        default: return w.3 & bit != 0
        }
    }

    mutating func insert(_ b: UInt8) {
        let bit = UInt64(1) << UInt64(b & 63)
        switch b >> 6 {
        case 0: w.0 |= bit
        case 1: w.1 |= bit
        case 2: w.2 |= bit
        default: w.3 |= bit
        }
    }

    mutating func insert(_ range: ClosedRange<UInt8>) { for b in range { insert(b) } }
    mutating func formUnion(_ o: ByteSet) { w = (w.0 | o.w.0, w.1 | o.w.1, w.2 | o.w.2, w.3 | o.w.3) }
    var count: Int { w.0.nonzeroBitCount + w.1.nonzeroBitCount + w.2.nonzeroBitCount + w.3.nonzeroBitCount }
    var isEmpty: Bool { count == 0 }
    var firstMember: UInt8? {
        for b in 0...255 where contains(UInt8(b)) { return UInt8(b) }
        return nil
    }
    var only: UInt8? {
        guard count == 1 else { return nil }
        for b in 0...255 where contains(UInt8(b)) { return UInt8(b) }
        return nil
    }
}

/// Inside a JSON string (after the opening quote): the bytes left in the budget; a pending escape (0 none, 1 after a backslash,
/// 2...5 for the hex digits of `\\u` still to come + 1); and the UTF-8 continuation bytes still to come with the range the next
/// one must be in. `\\uD800`...`\\uDFFF` (UTF-16 surrogates) are never allowed: written alone they are not valid JSON text for
/// `JSONDecoder` and `JSONSerialization`, and a character outside the basic plane is written as raw UTF-8 instead.
struct StrState: Hashable, Sendable {
    var rem: Int32
    /// Bytes still to be written before the string may close (a minimum length; 0 = may close at once). Every byte counts, whatever it is.
    var minLeft: UInt16 = 0
    var esc: UInt8 = 0
    /// After `\\u`, the first hex digit was `d` or `D`: the second must then be 0...7.
    var dFirst = false
    var cont: UInt8 = 0
    var lo: UInt8 = 0
    var hi: UInt8 = 0
    /// The last byte written was a plain space. A value never needs to end in one (values are trimmed), and the model that ends a
    /// string after a space is almost always opening an inner quote it should have escaped (`como "x"`): the grammar took the raw
    /// quote as the end of the string and the model went on with the next key inside the minutes (11b, summary of cdm191218_a).
    /// With the closing quote refused after a space, the model writes `\"` (allowed), `«` or goes on with a letter.
    var lastSpace = false
    /// An escaped quote (`\"`) was opened and not yet closed by another: while it is open (and room remains) the raw quote does not
    /// close the string. A model that escapes the opening quote of an inner quotation (`\"presupuesto`) but ends it with a raw `"`
    /// would otherwise cut the value there and write the rest as the next key.
    var innerQuoteOpen = false
    /// Bytes written since that escaped quote opened. A model that writes one `\"` (an inch mark, an opening quote it never closes) must
    /// still be able to end its string: after this many bytes the raw quote closes it again.
    var innerAge: UInt16 = 0
    static let innerQuoteReach: UInt16 = 160
    /// The open escaped quote still holds the raw closing quote back.
    var innerBinding: Bool { innerQuoteOpen && innerAge < Self.innerQuoteReach }

    enum Step { case stay, closed, bad }

    /// Bytes that may come next (the closing quote always may, between characters).
    var allowedBytes: ByteSet {
        var set = ByteSet()
        if esc == 1 {
            if rem >= 1 { for c in "\"\\/bfnrt".utf8 { set.insert(c) } }
            if rem >= 5 { set.insert(UInt8(ascii: "u")) }
        } else if esc >= 2 {
            if rem >= 1 {
                if esc == 4, dFirst { set.insert(0x30...0x37) } else { set.insert(0x30...0x39); set.insert(0x41...0x46); set.insert(0x61...0x66) }
            }
        } else if cont > 0 {
            if rem >= 1 { set.insert(lo...hi) }
        } else {
            // With no room left the string must close, space or not.
            if minLeft == 0, (!lastSpace && !innerBinding) || rem < 1 { set.insert(UInt8(ascii: "\"")) }
            if rem >= 1 {
                set.insert(0x20...0x21); set.insert(0x23...0x5B); set.insert(0x5D...0x7F)
                if rem >= 2 { set.insert(UInt8(ascii: "\\")); set.insert(0xC2...0xDF) }
                if rem >= 3 { set.insert(0xE0...0xEF) }
                if rem >= 4 { set.insert(0xF0...0xF4) }
            }
        }
        return set
    }

    /// Consumes a byte: `.closed` for the closing quote (the string is over; not before the minimum length is written).
    mutating func advance(_ b: UInt8) -> Step {
        let plain = esc == 0 && cont == 0
        if b == UInt8(ascii: "\""), plain, minLeft > 0 || ((lastSpace || innerBinding) && rem >= 1) { return .bad }
        let escapedQuote = esc == 1 && b == UInt8(ascii: "\"")
        let step = advanceByte(b)
        if step == .stay {
            if escapedQuote { innerQuoteOpen.toggle(); innerAge = 0 } else if innerQuoteOpen, innerAge < Self.innerQuoteReach { innerAge += 1 }
            if minLeft > 0 { minLeft -= 1 }
            lastSpace = plain && b == 0x20
        }
        return step
    }

    private mutating func advanceByte(_ b: UInt8) -> Step {
        if esc == 1 {
            guard rem >= 1 else { return .bad }
            switch b {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                rem -= 1; esc = 0
                return .stay
            case UInt8(ascii: "u"):
                guard rem >= 5 else { return .bad }
                rem -= 1; esc = 5   // four hex digits to come: esc = 1 + 4
                return .stay
            default: return .bad
            }
        }
        if esc >= 2 {
            guard (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66), rem >= 1 else { return .bad }
            if esc == 4, dFirst, b > 0x37 { return .bad }   // \uD8xx...\uDFxx: a surrogate
            if esc == 5 { dFirst = b == UInt8(ascii: "d") || b == UInt8(ascii: "D") }
            rem -= 1; esc = esc == 2 ? 0 : esc - 1
            if esc == 0 { dFirst = false }
            return .stay
        }
        if cont > 0 {
            guard b >= lo, b <= hi, rem >= 1 else { return .bad }
            rem -= 1; cont -= 1; lo = 0x80; hi = 0xBF
            return .stay
        }
        if b == UInt8(ascii: "\"") { return .closed }
        if b == UInt8(ascii: "\\") {
            guard rem >= 2 else { return .bad }
            rem -= 1; esc = 1
            return .stay
        }
        guard rem >= 1 else { return .bad }
        if b >= 0x20 && b < 0x80 {
            rem -= 1
            return .stay
        }
        // UTF-8 lead bytes with the ranges of the standard (no overlong forms, no surrogates, nothing above U+10FFFF).
        let need: UInt8, l: UInt8, h: UInt8
        switch b {
        case 0xC2...0xDF: need = 1; l = 0x80; h = 0xBF
        case 0xE0: need = 2; l = 0xA0; h = 0xBF
        case 0xE1...0xEC, 0xEE...0xEF: need = 2; l = 0x80; h = 0xBF
        case 0xED: need = 2; l = 0x80; h = 0x9F
        case 0xF0: need = 3; l = 0x90; h = 0xBF
        case 0xF1...0xF3: need = 3; l = 0x80; h = 0xBF
        case 0xF4: need = 3; l = 0x80; h = 0x8F
        default: return .bad
        }
        guard Int32(need) < rem else { return .bad }   // the whole character must fit
        rem -= 1; cont = need; lo = l; hi = h
        return .stay
    }
}

/// One thing the decoder is in the middle of. The stack of frames is the whole state of the grammar.
enum GFrame: Hashable, Sendable {
    /// A value of node `n`, before its first byte.
    case value(Int)
    /// The rest of literal `id`, at byte `pos`.
    case lit(Int, Int)
    /// Inside a string (after the opening quote): bytes left in the budget; a pending escape (0 none, 1 after a backslash, 2...5
    /// the hex digits still to come + 1); the UTF-8 continuation bytes still to come and the range the next one must be in.
    case str(StrState)
    /// A walk through the trie `id` (a closed set of strings or integers), at state `state`.
    case trie(Int, Int32)
    /// An integer of any size: digits so far (0 = none yet, 255 = a lone zero).
    case num(Int, UInt8)
    /// After `[`: an item or `]`.
    case arrayOpen(Int)
    /// After an item (`count` so far): `,` and another item, or `]`.
    case arrayAfter(Int, Int)
    /// A fixed pattern of character classes (a date), at position `pos`.
    case pat(Int, Int)
    /// Optional JSON whitespace (spaces and line feeds) between two tokens, at most this many more bytes. Only in a grammar built
    /// with `whitespace: true`.
    case ws(UInt8)
}

/// The compiled form of an `OutputSchema`: nodes, literals, tries and patterns. Immutable and shareable.
final class SchemaGrammar: @unchecked Sendable {
    enum Node {
        /// `sep` is the literal before a key in a grammar with whitespace (`{` or `,`; -1 = it is part of `prefix`), `prefix` the key
        /// with its colon (and the separator when `sep` is -1), `close` the closing brace (-1 = none: a tagged object's tail closes
        /// it), `leadingSpace` whether whitespace may come before the first separator.
        case object(props: [(sep: Int, prefix: Int, node: Int)], close: Int, leadingSpace: Bool)
        case array(item: Int, min: Int, max: Int, open: Int, close: Int, comma: Int)
        case string(maxBytes: Int, minBytes: Int, quote: Int)
        case trie(Int)
        case num(maxDigits: Int)
        /// A date inside quotes: the year as a pattern (`"YYYY-`), then month and day from a closed set (`MM-DD"`), so 13-45 and
        /// 00-00 cannot be written.
        case date(pattern: Int, tail: Int)
        case nullable(inner: Int, nullLit: Int)
    }

    struct Trie {
        var transitions: [[UInt8: Int32]] = [[:]]
        var terminal: [Bool] = [false]
        /// What follows a word that ends in this state (a tagged object's tail), when anything does.
        var next: [Int32: Int] = [:]

        /// The shortest bytes that lead from `state` to a complete word (empty when `state` is one); nil when there is none (an empty
        /// set). Ties go to the smallest byte, so the result is always the same.
        func shortest(from state: Int32) -> [UInt8]? {
            var parent: [Int32: (from: Int32, byte: UInt8)] = [:]
            var seen: Set<Int32> = [state]
            var queue: [Int32] = [state]
            var head = 0
            while head < queue.count {
                let s = queue[head]
                head += 1
                if terminal[Int(s)] {
                    var out: [UInt8] = []
                    var cur = s
                    while cur != state, let p = parent[cur] { out.append(p.byte); cur = p.from }
                    return out.reversed()
                }
                for (b, n) in transitions[Int(s)].sorted(by: { $0.key < $1.key }) where !seen.contains(n) {
                    seen.insert(n)
                    parent[n] = (s, b)
                    queue.append(n)
                }
            }
            return nil
        }
    }

    private(set) var nodes: [Node] = []
    private(set) var literals: [[UInt8]] = []
    private(set) var tries: [Trie] = []
    private(set) var patterns: [[ByteSet]] = []
    let root: Int
    /// Optional bounded whitespace between tokens (see `GFrame.ws`).
    let whitespace: Bool
    /// The longest run of whitespace between two tokens.
    static let maxWhitespace: UInt8 = 12

    init(_ schema: OutputSchema, whitespace: Bool = false) {
        self.whitespace = whitespace
        root = 0
        nodes.append(.num(maxDigits: 1))
        let id = compile(schema)
        nodes[0] = nodes[id]
        // `root` is node 0: a copy of the compiled root (children refer to other ids).
    }

    /// The shortest complete instance of node `n` as bytes (`null` for a nullable, `""` for a string, the fewest items an array needs);
    /// nil when the node cannot be completed (a closed set with no member).
    func minimal(_ n: Int) -> [UInt8]? {
        switch nodes[n] {
        case .object(let props, let close, _):
            var out: [UInt8] = []
            for p in props {
                guard let v = minimal(p.node) else { return nil }
                out += (p.sep >= 0 ? literals[p.sep] : []) + literals[p.prefix] + v
            }
            return close >= 0 ? out + literals[close] : out
        case .array(let item, let lo, _, let open, let close, let comma):
            var out = literals[open]
            for i in 0..<lo {
                guard let v = minimal(item) else { return nil }
                if i > 0 { out += literals[comma] }
                out += v
            }
            return out + literals[close]
        case .string(_, let lo, let quote):
            // The shortest valid text: the minimum length in dots (a dot has no letter or digit in it, so a text made of them is
            // recognisable as one the model did not write).
            return literals[quote] + [UInt8](repeating: UInt8(ascii: "."), count: lo) + literals[quote]
        case .trie(let t): return shortest(inTrie: t, from: 0)
        case .num: return [UInt8(ascii: "0")]
        case .date(let p, let t): return patterns[p].map { $0.firstMember ?? 0x30 } + (tries[t].shortest(from: 0) ?? [])
        case .nullable(let inner, let nullLit): _ = inner
            return literals[nullLit]
        }
    }

    /// The shortest complete word of trie `t` from `state`, with what must follow it (the tail of a tagged object); ties go to the
    /// smallest bytes. nil when no word can be completed.
    func shortest(inTrie t: Int, from state: Int32) -> [UInt8]? {
        let trie = tries[t]
        if trie.next.isEmpty { return trie.shortest(from: state) }
        // Cheapest word plus tail: every word reachable from `state`.
        var best: [UInt8]?
        var parent: [Int32: (from: Int32, byte: UInt8)] = [:]
        var seen: Set<Int32> = [state]
        var queue: [Int32] = [state]
        var head = 0
        while head < queue.count {
            let s = queue[head]
            head += 1
            if trie.terminal[Int(s)] {
                var tail: [UInt8]? = []
                if let n = trie.next[s] { tail = minimal(n) }
                if let tail {
                    var word: [UInt8] = []
                    var cur = s
                    while cur != state, let p = parent[cur] { word.append(p.byte); cur = p.from }
                    let candidate = Array(word.reversed()) + tail
                    if best == nil || candidate.count < best!.count { best = candidate }
                }
            }
            for (b, n) in trie.transitions[Int(s)].sorted(by: { $0.key < $1.key }) where !seen.contains(n) {
                seen.insert(n)
                parent[n] = (s, b)
                queue.append(n)
            }
        }
        return best
    }

    private func lit(_ s: String) -> Int {
        let b = Array(s.utf8)
        if let i = literals.firstIndex(of: b) { return i }
        literals.append(b)
        return literals.count - 1
    }

    private func trie(_ words: [String], next: [Int]? = nil) -> Int {
        var t = Trie()
        for (index, w) in words.enumerated() {
            var s: Int32 = 0
            for b in w.utf8 {
                if let n = t.transitions[Int(s)][b] { s = n } else {
                    t.transitions.append([:])
                    t.terminal.append(false)
                    let n = Int32(t.transitions.count - 1)
                    t.transitions[Int(s)][b] = n
                    s = n
                }
            }
            t.terminal[Int(s)] = true
            if let next { t.next[s] = next[index] }
        }
        tries.append(t)
        return tries.count - 1
    }

    /// The literals and child nodes of an object's properties. Without whitespace the separator is part of the key's literal.
    private func compileProperties(_ props: [OutputSchema.Property], first: Bool) -> [(sep: Int, prefix: Int, node: Int)] {
        props.enumerated().map { i, p in
            let separator = i == 0 && first ? "{" : ","
            let key = "\"" + p.name + "\":"
            let node = compile(p.schema)
            return whitespace ? (lit(separator), lit(key), node) : (-1, lit(separator + key), node)
        }
    }

    private func compile(_ s: OutputSchema) -> Int {
        let id = nodes.count
        nodes.append(.num(maxDigits: 1))
        switch s {
        case .object(let props):
            nodes[id] = .object(props: compileProperties(props, first: true), close: lit("}"), leadingSpace: false)
        case .tagged(let key, let cases):
            // `{"key": <word>` and then, by the word, the other properties: a branch of the grammar that closes the object itself.
            let tails = cases.map { c -> Int in
                let tail = nodes.count
                nodes.append(.num(maxDigits: 1))
                nodes[tail] = .object(props: compileProperties(c.rest, first: false), close: lit("}"), leadingSpace: true)
                return tail
            }
            let branch = nodes.count
            nodes.append(.trie(trie(cases.map(\.value), next: tails)))
            let name = "\"" + key + "\":"
            let head = whitespace ? (sep: lit("{"), prefix: lit(name), node: branch) : (sep: -1, prefix: lit("{" + name), node: branch)
            nodes[id] = .object(props: [head], close: -1, leadingSpace: false)
        case .array(let item, let lo, let hi):
            nodes[id] = .array(item: compile(item), min: lo, max: hi, open: lit("["), close: lit("]"), comma: lit(","))
        case .string(let n): nodes[id] = .string(maxBytes: n, minBytes: 0, quote: lit("\""))
        case .text(let lo, let hi): nodes[id] = .string(maxBytes: hi, minBytes: lo, quote: lit("\""))
        case .enumStrings(let values): nodes[id] = .trie(trie(values.map { "\"" + $0 + "\"" }))
        case .integers(let set): nodes[id] = .trie(trie(set.sorted().map(String.init)))
        case .anyInteger(let d): nodes[id] = .num(maxDigits: d)
        case .boolean: nodes[id] = .trie(trie(["true", "false"]))
        case .date:
            var classes: [ByteSet] = []
            func one(_ b: UInt8) { var c = ByteSet(); c.insert(b); classes.append(c) }
            func digits(_ r: ClosedRange<UInt8>) { var c = ByteSet(); c.insert(r); classes.append(c) }
            one(UInt8(ascii: "\"")); digits(0x31...0x39); digits(0x30...0x39); digits(0x30...0x39); digits(0x30...0x39)
            one(UInt8(ascii: "-"))
            patterns.append(classes)
            // Month and day: every real one (29 February is allowed: whether the year has one is for the validator).
            let days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            let tail = days.enumerated().flatMap { m, n in (1...n).map { String(format: "%02d-%02d\"", m + 1, $0) } }
            nodes[id] = .date(pattern: patterns.count - 1, tail: trie(tail))
        case .nullable(let inner): nodes[id] = .nullable(inner: compile(inner), nullLit: lit("null"))
        }
        return id
    }
}
