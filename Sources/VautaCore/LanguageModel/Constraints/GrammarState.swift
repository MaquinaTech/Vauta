// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The state of a decoding: the frames on a stack. A small value type: copying it is cheap.
struct GrammarState: Hashable, Sendable {
    var stack: [GFrame]

    static func start(_ g: SchemaGrammar) -> GrammarState {
        var s = GrammarState(stack: [.value(g.root)])
        s.settle(g)
        return s
    }

    var isFinished: Bool { stack.isEmpty }

    /// Expands frames that need no byte to be decided: an object is its literals and values, an array starts with `[`, a string
    /// with its quote, a closed set or number with its walk.
    mutating func settle(_ g: SchemaGrammar) {
        while case .value(let n)? = stack.last {
            switch g.nodes[n] {
            case .object(let props, let close, let leadingSpace):
                stack.removeLast()
                if close >= 0 { stack.append(.lit(close, 0)) }
                let space = g.whitespace
                for (i, p) in props.enumerated().reversed() {
                    // `sep ws key ws value ws`: no space after the last value of an object that has no closing brace of its own.
                    if space, close >= 0 || i < props.count - 1 { stack.append(.ws(SchemaGrammar.maxWhitespace)) }
                    stack.append(.value(p.node))
                    if space { stack.append(.ws(SchemaGrammar.maxWhitespace)) }
                    stack.append(.lit(p.prefix, 0))
                    if p.sep >= 0 {
                        if space { stack.append(.ws(SchemaGrammar.maxWhitespace)) }
                        stack.append(.lit(p.sep, 0))
                    }
                }
                if space, leadingSpace { stack.append(.ws(SchemaGrammar.maxWhitespace)) }
            case .array(_, _, _, let open, _, _):
                stack.removeLast()
                stack.append(.arrayOpen(n))
                if g.whitespace { stack.append(.ws(SchemaGrammar.maxWhitespace)) }
                stack.append(.lit(open, 0))
            case .string(let maxBytes, let minBytes, let quote):
                stack.removeLast()
                stack.append(.str(StrState(rem: Int32(maxBytes), minLeft: UInt16(clamping: minBytes))))
                stack.append(.lit(quote, 0))
            case .trie(let t):
                stack.removeLast()
                stack.append(.trie(t, 0))
            case .num(let maxDigits):
                stack.removeLast()
                stack.append(.num(0, UInt8(clamping: maxDigits)))
            case .date(let p, let t):
                stack.removeLast()
                stack.append(.trie(t, 0))
                stack.append(.pat(p, 0))
            case .nullable:
                return   // needs the first byte
            }
        }
    }

    enum Completion: Equatable {
        /// The shortest bytes that make the value complete.
        case bytes([UInt8])
        /// In the middle of a character or an escape inside a string: a few more bytes must come from the model first.
        case pending
        /// No completion exists (a closed set with no member).
        case impossible
    }

    /// The shortest continuation that ends the value in a valid instance of the schema: finish the string, `null` or the least value
    /// for every field still to come, the items an array still needs, and the closing brackets. Used when the output budget or the
    /// loop guard ends decoding, so that the text is still valid JSON.
    func shortestCompletion(_ g: SchemaGrammar) -> Completion {
        var out: [UInt8] = []
        for frame in stack.reversed() {
            switch frame {
            case .value(let n):
                guard let m = g.minimal(n) else { return .impossible }
                out += m
            case .lit(let id, let pos): out += g.literals[id][pos...]
            case .str(let st):
                if st.esc != 0 || st.cont != 0 { return .pending }
                out += [UInt8](repeating: UInt8(ascii: "."), count: Int(st.minLeft))
                // The closing quote is refused right after a space: one filler byte first. Also while an escaped inner quote is open
                // (after the minimum length is written): it is closed with its own `\"` when there is room for it.
                let room = Int(st.rem) - Int(st.minLeft)
                if st.innerBinding, room >= 2 { out += [UInt8(ascii: "\\"), UInt8(ascii: "\"")] }
                else if (st.minLeft == 0 && st.lastSpace) || st.innerBinding, room >= 1 { out.append(UInt8(ascii: ".")) }
                out.append(UInt8(ascii: "\""))
            case .trie(let id, let st):
                guard let w = g.shortest(inTrie: id, from: st) else { return .impossible }
                out += w
            case .num(let digits, _):
                if digits == 0 { out.append(UInt8(ascii: "0")) }
            case .arrayOpen(let n), .arrayAfter(let n, _):
                guard case .array(let item, let lo, _, _, _, let comma) = g.nodes[n] else { return .impossible }
                var have = 0
                var first = true
                if case .arrayAfter(_, let count) = frame { have = count; first = false }
                if have < lo {
                    guard let v = g.minimal(item) else { return .impossible }
                    for _ in have..<lo {
                        if !first { out += g.literals[comma] }
                        first = false
                        out += v
                    }
                }
                out.append(UInt8(ascii: "]"))
            case .pat(let p, let pos): out += g.patterns[p][pos...].map { $0.firstMember ?? 0x30 }
            case .ws: break
            }
        }
        return .bytes(out)
    }

    /// Bytes that may come next.
    func allowed(_ g: SchemaGrammar) -> ByteSet {
        guard let top = stack.last else { return ByteSet() }
        var set = ByteSet()
        switch top {
        case .value(let n):
            if case .nullable(let inner, _) = g.nodes[n] {
                set.insert(UInt8(ascii: "n"))
                var s = self
                s.stack[s.stack.count - 1] = .value(inner)
                s.settle(g)
                set.formUnion(s.allowed(g))
            }
        case .lit(let id, let pos): set.insert(g.literals[id][pos])
        case .str(let st): set = st.allowedBytes
        case .trie(let id, let st):
            let t = g.tries[id]
            for b in t.transitions[Int(st)].keys { set.insert(b) }
            if t.terminal[Int(st)] {
                var s = self
                s.finishTrie(id, st, g)
                set.formUnion(s.allowed(g))
            }
        case .num(let digits, let flag):
            // `flag` carries the digit budget until the first digit, and 255 after a lone zero.
            if digits == 0 {
                set.insert(0x30...0x39)
            } else {
                if flag != 255, digits < Int(flag) { set.insert(0x30...0x39) }
                var s = self
                s.stack.removeLast()
                s.settle(g)
                set.formUnion(s.allowed(g))
            }
        case .arrayOpen(let n):
            if case .array(let item, let lo, let hi, _, _, _) = g.nodes[n] {
                if lo == 0 { set.insert(UInt8(ascii: "]")) }
                if hi > 0 {
                    var s = self
                    s.stack[s.stack.count - 1] = .value(item)
                    s.settle(g)
                    set.formUnion(s.allowed(g))
                }
            }
        case .arrayAfter(let n, let count):
            if case .array(_, let lo, let hi, _, _, _) = g.nodes[n] {
                if count < hi { set.insert(UInt8(ascii: ",")) }
                if count >= lo { set.insert(UInt8(ascii: "]")) }
            }
        case .pat(let p, let pos): set = g.patterns[p][pos]
        case .ws(let left):
            if left > 0 { set.insert(UInt8(ascii: " ")); set.insert(UInt8(ascii: "\n")) }
            var s = self
            s.stack.removeLast()
            s.settle(g)
            set.formUnion(s.allowed(g))
        }
        return set
    }

    /// Consumes one byte; false when the grammar does not allow it (the state is then unspecified).
    mutating func step(_ b: UInt8, _ g: SchemaGrammar) -> Bool {
        guard let top = stack.last else { return false }
        switch top {
        case .value(let n):
            guard case .nullable(let inner, let nullLit) = g.nodes[n] else { return false }
            if b == UInt8(ascii: "n") {
                stack[stack.count - 1] = .lit(nullLit, 1)
                return true
            }
            stack[stack.count - 1] = .value(inner)
            settle(g)
            return step(b, g)
        case .lit(let id, let pos):
            guard g.literals[id][pos] == b else { return false }
            if pos + 1 == g.literals[id].count { stack.removeLast(); settle(g) } else { stack[stack.count - 1] = .lit(id, pos + 1) }
            return true
        case .str(var st):
            switch st.advance(b) {
            case .bad: return false
            case .closed:
                stack.removeLast()
                settle(g)
            case .stay: stack[stack.count - 1] = .str(st)
            }
            return true
        case .trie(let id, let st):
            let t = g.tries[id]
            if let next = t.transitions[Int(st)][b] {
                stack[stack.count - 1] = .trie(id, next)
                if t.terminal[Int(next)], t.transitions[Int(next)].isEmpty { finishTrie(id, next, g) }
                return true
            }
            guard t.terminal[Int(st)] else { return false }
            finishTrie(id, st, g)
            return step(b, g)
        case .num(let digits, let flag):
            if b >= 0x30 && b <= 0x39 {
                if digits == 0 {
                    stack[stack.count - 1] = .num(1, b == 0x30 ? 255 : flag)
                    return true
                }
                guard flag != 255, digits < Int(flag) else { return false }
                stack[stack.count - 1] = .num(digits + 1, flag)
                return true
            }
            guard digits > 0 else { return false }
            stack.removeLast()
            settle(g)
            return step(b, g)
        case .arrayOpen(let n):
            guard case .array(let item, let lo, let hi, _, _, _) = g.nodes[n] else { return false }
            if b == UInt8(ascii: "]"), lo == 0 {
                stack.removeLast()
                settle(g)
                return true
            }
            guard hi > 0 else { return false }
            stack[stack.count - 1] = .arrayAfter(n, 1)
            if g.whitespace { stack.append(.ws(SchemaGrammar.maxWhitespace)) }
            stack.append(.value(item))
            settle(g)
            return step(b, g)
        case .arrayAfter(let n, let count):
            guard case .array(let item, let lo, let hi, _, _, _) = g.nodes[n] else { return false }
            if b == UInt8(ascii: ","), count < hi {
                stack[stack.count - 1] = .arrayAfter(n, count + 1)
                if g.whitespace { stack.append(.ws(SchemaGrammar.maxWhitespace)) }
                stack.append(.value(item))
                if g.whitespace { stack.append(.ws(SchemaGrammar.maxWhitespace)) }
                settle(g)
                return true
            }
            if b == UInt8(ascii: "]"), count >= lo {
                stack.removeLast()
                settle(g)
                return true
            }
            return false
        case .pat(let p, let pos):
            guard g.patterns[p][pos].contains(b) else { return false }
            if pos + 1 == g.patterns[p].count { stack.removeLast(); settle(g) } else { stack[stack.count - 1] = .pat(p, pos + 1) }
            return true
        case .ws(let left):
            if left > 0, b == UInt8(ascii: " ") || b == UInt8(ascii: "\n") {
                stack[stack.count - 1] = .ws(left - 1)
                return true
            }
            stack.removeLast()
            settle(g)
            return step(b, g)
        }
    }

    /// A walk through trie `id` ended in `state`: the frame goes, and what the word calls for (the tail of a tagged object) comes.
    private mutating func finishTrie(_ id: Int, _ state: Int32, _ g: SchemaGrammar) {
        stack.removeLast()
        if let tail = g.tries[id].next[state] { stack.append(.value(tail)) }
        settle(g)
    }
}
