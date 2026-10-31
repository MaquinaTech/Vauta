// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// The vocabulary as bytes and as a trie, for deciding which tokens a grammar allows. Built once per tokenizer.
final class TokenIndex: @unchecked Sendable {
    let size: Int
    let bytes: [[UInt8]]
    let isValid: [Bool]
    let maxLength: Int
    // Trie in first-child / next-sibling form.
    private(set) var firstChild: [Int32] = [-1]
    private(set) var nextSibling: [Int32] = [-1]
    private(set) var edge: [UInt8] = [0]
    private(set) var firstToken: [Int32] = [-1]
    private(set) var nextToken: [Int32]
    let words: Int
    /// What each small string state allows, shared by every grammar over this vocabulary.
    fileprivate let stringEntries = Mutex<[StrState: TokenMaskEngine.StringEntry]>([:])

    convenience init(tokenizer: GemmaTokenizer) {
        let all = tokenizer.allTokenBytes
        self.init(bytes: all, control: (0..<all.count).map { tokenizer.isControl(Int32($0)) })
    }

    /// A vocabulary given directly: the bytes of each token and whether it is a control token (tests use small ones).
    init(bytes all: [[UInt8]], control: [Bool]) {
        size = all.count
        words = (all.count + 63) / 64
        bytes = all
        var valid = [Bool](repeating: false, count: all.count)
        var longest = 1
        nextToken = [Int32](repeating: -1, count: all.count)
        for (id, b) in all.enumerated() where !b.isEmpty && !control[id] {
            valid[id] = true
            longest = max(longest, b.count)
            var node: Int32 = 0
            for byte in b {
                var c = firstChild[Int(node)]
                while c >= 0, edge[Int(c)] != byte { c = nextSibling[Int(c)] }
                if c < 0 {
                    firstChild.append(-1); nextSibling.append(firstChild[Int(node)]); edge.append(byte); firstToken.append(-1)
                    c = Int32(firstChild.count - 1)
                    firstChild[Int(node)] = c
                }
                node = c
            }
            nextToken[id] = firstToken[Int(node)]
            firstToken[Int(node)] = Int32(id)
        }
        isValid = valid
        maxLength = longest
    }

    @inline(__always) func children(of node: Int32) -> Int32 { firstChild[Int(node)] }
}

/// Which tokens a grammar state allows, as a bitset over the vocabulary. Strings are the hot case (almost every token is allowed
/// inside one), so their masks come from a per-vocabulary table keyed by the string's small state; everything else walks the
/// trie, which prunes at once because few bytes are allowed. Masks are cached by state.
final class TokenMaskEngine: @unchecked Sendable {
    let grammar: SchemaGrammar
    let index: TokenIndex
    private let lock = Mutex(Caches())

    fileprivate struct StringEntry {
        var inside: [UInt64]
        var closers: [(token: Int32, offset: Int)]
    }

    private struct Caches {
        var masks: [GrammarState: [UInt64]] = [:]
        var order: [GrammarState] = []
        var closed: [ClosedKey: [UInt64]] = [:]
    }

    private struct ClosedKey: Hashable { let str: StrState; let rest: GrammarState }

    static let maxCachedMasks = 512

    init(grammar: SchemaGrammar, index: TokenIndex) {
        self.grammar = grammar
        self.index = index
    }

    private func emptyMask() -> [UInt64] { [UInt64](repeating: 0, count: index.words) }

    /// The tokens allowed in `state` (never the stop token: the constraint adds that when the value is complete).
    func mask(for state: GrammarState) -> [UInt64] {
        if let cached = lock.withLock({ $0.masks[state] }) { return cached }
        let m: [UInt64]
        if case .str(let s)? = state.stack.last { m = stringMask(state, s) } else { m = walkMask(state) }
        lock.withLock { c in
            if c.masks.count >= Self.maxCachedMasks, let oldest = c.order.first {
                c.masks[oldest] = nil
                c.order.removeFirst()
            }
            c.masks[state] = m
            c.order.append(state)
        }
        return m
    }

    // MARK: Walking the trie

    private func walkMask(_ state: GrammarState) -> [UInt64] {
        var out = emptyMask()
        walk(0, state, &out)
        return out
    }

    private func walk(_ node: Int32, _ state: GrammarState, _ out: inout [UInt64]) {
        var t = index.firstToken[Int(node)]
        while t >= 0 {
            out[Int(t) >> 6] |= 1 << UInt64(t & 63)
            t = index.nextToken[Int(t)]
        }
        if state.isFinished { return }
        let allowed = state.allowed(grammar)
        var c = index.children(of: node)
        while c >= 0 {
            let b = index.edge[Int(c)]
            if allowed.contains(b) {
                var next = state
                if next.step(b, grammar) { walk(c, next, &out) }
            }
            c = index.nextSibling[Int(c)]
        }
    }

    // MARK: Strings

    private func stringKey(_ s: StrState) -> StrState {
        var k = s
        // Beyond the longest token the budget makes no difference.
        k.rem = min(k.rem, Int32(index.maxLength + 4))
        return k
    }

    private func stringEntry(_ key: StrState) -> StringEntry {
        if let e = index.stringEntries.withLock({ $0[key] }) { return e }
        var inside = emptyMask()
        var closers: [(Int32, Int)] = []
        for t in 0..<index.size where index.isValid[t] {
            var s = key
            let b = index.bytes[t]
            var ok = true
            var i = 0
            while i < b.count {
                switch s.advance(b[i]) {
                case .bad: ok = false
                case .closed:
                    closers.append((Int32(t), i))
                    ok = false
                case .stay: break
                }
                if !ok { break }
                i += 1
            }
            if ok { inside[t >> 6] |= 1 << UInt64(t & 63) }
        }
        let e = StringEntry(inside: inside, closers: closers.map { (token: $0.0, offset: $0.1) })
        index.stringEntries.withLock { $0[key] = e }
        return e
    }

    private func stringMask(_ state: GrammarState, _ s: StrState) -> [UInt64] {
        let key = stringKey(s)
        let entry = stringEntry(key)
        var rest = state
        rest.stack.removeLast()
        let ck = ClosedKey(str: key, rest: rest)
        let closedMask: [UInt64]
        if let c = lock.withLock({ $0.closed[ck] }) { closedMask = c } else {
            var m = emptyMask()
            var restSettled = rest
            restSettled.settle(grammar)
            for (t, offset) in entry.closers {
                var next = restSettled
                var ok = true
                let b = index.bytes[Int(t)]
                var i = offset + 1
                while i < b.count {
                    if next.isFinished || !next.step(b[i], grammar) { ok = false; break }
                    i += 1
                }
                if ok { m[Int(t) >> 6] |= 1 << UInt64(t & 63) }
            }
            closedMask = m
            lock.withLock { $0.closed[ck] = m }
        }
        var out = entry.inside
        for i in 0..<out.count { out[i] |= closedMask[i] }
        return out
    }
}

extension GrammarState {
    /// Bytes that are forced from here on (one possible byte at a time), up to `limit`.
    func forcedBytes(_ g: SchemaGrammar, limit: Int = 512) -> [UInt8] {
        var s = self
        var out: [UInt8] = []
        while out.count < limit, !s.isFinished, let b = s.allowed(g).only {
            guard s.step(b, g) else { break }
            out.append(b)
        }
        return out
    }
}

/// Decoding constrained to an `OutputSchema`: only tokens that keep the output a valid instance of the schema are allowed, the
/// punctuation and keys (which have only one valid continuation) are written without asking the model, and after the closing
/// brace the stop token is forced, so the model cannot add text around the JSON.
public final class SchemaConstraint: OutputConstraint, @unchecked Sendable {
    private let engine: TokenMaskEngine
    /// The grammar state and the statistics, together under one lock.
    private struct Inner {
        var state: GrammarState
        var stats = Stats()
        /// The grammar refused a byte of an accepted token: its state is unspecified, so nothing more is asked of it.
        var broken = false
    }
    private let inner = Mutex(Inner(state: GrammarState(stack: [])))
    public static let stopToken: Int32 = 106
    private let stop: Int32
    /// Statistics for the evaluation: masks asked, forced sequences, forced tokens.
    public var stats: Stats { inner.withLock { $0.stats } }

    public struct Stats: Sendable, Equatable {
        public var masks = 0
        public var forcedSequences = 0
        public var forcedTokens = 0
        public var maskSeconds = 0.0
        /// The time of each `nextMask` call that computed a mask (forced sequences excluded), in order, up to `maxRecorded`; for
        /// the percentiles of the evaluation.
        public var maskDurations: [Double] = []
        public static let maxRecorded = 50_000
        /// Tokens whose bytes the grammar did not allow. Zero unless the mask or the token table is wrong.
        public var stepFailures = 0
    }

    private let encodeForced: @Sendable (String) -> [Int32]
    private let tokenBytes: @Sendable (Int32) -> [UInt8]

    public convenience init(schema: OutputSchema, tokenizer: GemmaTokenizer, whitespace: Bool = true) {
        self.init(grammar: SchemaGrammar(schema, whitespace: whitespace), stop: Self.stopToken, index: TokenIndexCache.shared.index(for: tokenizer),
                  encode: { tokenizer.encodeLiteral($0) }, bytes: { tokenizer.tokenBytes($0) })
    }

    init(grammar g: SchemaGrammar, stop: Int32 = SchemaConstraint.stopToken, index: TokenIndex, encode: @escaping @Sendable (String) -> [Int32], bytes: @escaping @Sendable (Int32) -> [UInt8]) {
        self.stop = stop
        engine = TokenMaskEngine(grammar: g, index: index)
        encodeForced = encode
        tokenBytes = bytes
        inner.withLock { $0.state = GrammarState.start(g) }
    }

    /// Whether the value written so far is complete.
    public var isComplete: Bool { inner.withLock { $0.state.isFinished } }

    public func nextMask() -> TokenMask {
        let t0 = Date()
        let (state, broken) = inner.withLock { ($0.state, $0.broken) }
        // After a step the grammar refused the state is unspecified: end now, so the failure shows as an unfinished value that the
        // caller's validation rejects, and not as masks computed from a wrong state.
        if state.isFinished || broken { return .forced(stop) }
        let forced = state.forcedBytes(engine.grammar)
        if !forced.isEmpty {
            let ids = encodeForced(String(decoding: forced, as: UTF8.self))
            inner.withLock { s in
                s.stats.forcedSequences += 1
                s.stats.forcedTokens += ids.count
                s.stats.maskSeconds += Date().timeIntervalSince(t0)
            }
            return ids.count == 1 ? .forced(ids[0]) : .forcedSequence(ids)
        }
        let mask = engine.mask(for: state)
        inner.withLock { s in
            let dt = Date().timeIntervalSince(t0)
            s.stats.masks += 1
            s.stats.maskSeconds += dt
            if s.stats.maskDurations.count < Stats.maxRecorded { s.stats.maskDurations.append(dt) }
        }
        // A state nothing can follow (a closed set with no member): end at once instead of sampling from an empty set.
        if !mask.contains(where: { $0 != 0 }) { return .forced(stop) }
        return .allowed(mask)
    }

    public func closing() -> ConstraintClosing {
        let (state, broken) = inner.withLock { ($0.state, $0.broken) }
        if broken { return .unsupported }
        if state.isFinished { return .tokens([]) }
        switch state.shortestCompletion(engine.grammar) {
        case .pending: return .notYet
        case .impossible: return .unsupported
        case .bytes(let b): return .tokens(encodeForced(String(decoding: b, as: UTF8.self)))
        }
    }

    public func accept(_ token: Int32) {
        guard token != stop else { return }
        let g = engine.grammar
        inner.withLock { s in
            for b in tokenBytes(token) where !s.state.step(b, g) {
                s.stats.stepFailures += 1
                s.broken = true
                break
            }
        }
    }
}

/// One `TokenIndex` per tokenizer instance, shared by all constraints. The cache holds its tokenizer too: an identifier is an
/// address, and a tokenizer freed while its index stayed could let a new one at the same address find the wrong index.
final class TokenIndexCache: @unchecked Sendable {
    static let shared = TokenIndexCache()
    private let lock = NSLock()
    private var cached: [ObjectIdentifier: (tokenizer: GemmaTokenizer, index: TokenIndex)] = [:]

    /// Drops the indexes (tens of MB for the 262k-token vocabulary): the tokenizer was let go. Constraints in use keep their own.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        cached = [:]
    }

    /// The index of `tokenizer`, built once; a second caller waits for the first one's build.
    func index(for tokenizer: GemmaTokenizer) -> TokenIndex {
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(tokenizer)
        if let entry = cached[id] { return entry.index }
        let i = TokenIndex(tokenizer: tokenizer)
        cached[id] = (tokenizer, i)
        return i
    }

    /// Whether the index of `tokenizer` is built (for the tests).
    func hasIndex(for tokenizer: GemmaTokenizer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cached[ObjectIdentifier(tokenizer)] != nil
    }
}
