// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import VautaMLX

public enum GemmaTokenizerError: Error, Equatable, Sendable {
    case unreadable
    case badFormat
}

/// The Gemma BPE tokenizer in pure Swift, read from the model's `tokenizer.json` (Hugging Face tokenizers format).
///
/// Pipeline: added special tokens split the raw text, spaces become "▁", BPE runs over each segment (lowest merge rank
/// first, leftmost first) with byte fallback (`<0xXX>`). Zero mismatches against Hugging Face on 37,987 strings (spike 9c).
/// The vocabulary and merges are keyed by bytes (`[UInt8]`), not by `String`, because 434 groups of distinct tokens are
/// canonically equivalent and `String` equality would merge them.
public final class GemmaTokenizer: Sendable {
    public let bosID: Int32, eosID: Int32, padID: Int32, unkID: Int32

    private struct Merge: Sendable {
        let rank: Int32
        let newID: Int32
    }

    private struct Added: Sendable {
        let bytes: [UInt8]
        let id: Int32
    }

    private let vocab: [[UInt8]: Int32]
    private let merges: [UInt64: Merge]
    private let byteTokens: [Int32]
    private let added: [Added]
    private let addedFirst: Set<UInt8>
    private let decoder = DecoderTable()
    private static let space: [UInt8] = [0xE2, 0x96, 0x81]  // "▁"

    public convenience init(tokenizerJSON url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw GemmaTokenizerError.unreadable }
        try self.init(tokenizerJSON: data)
    }

    public init(tokenizerJSON data: Data) throws {
        let root: JV
        do { root = try ByteJSON.parse(data) } catch { throw GemmaTokenizerError.badFormat }
        guard case .obj(let vobj)? = root.get("model")?.get("vocab"), let m = root.get("model")?.get("merges")?.array
        else { throw GemmaTokenizerError.badFormat }
        var vocab: [[UInt8]: Int32] = [:]
        vocab.reserveCapacity(vobj.count)
        for (k, v) in vobj {
            guard let id = v.int, id >= 0, id < Int(Int32.max) else { throw GemmaTokenizerError.badFormat }
            vocab[k] = Int32(id)
        }
        var merges: [UInt64: Merge] = [:]
        merges.reserveCapacity(m.count)
        for (rank, item) in m.enumerated() {
            let a: [UInt8], b: [UInt8]
            if let p = item.array, p.count == 2, case .str(let x) = p[0], case .str(let y) = p[1] {
                a = x
                b = y
            } else if case .str(let s) = item, let sp = s.firstIndex(of: 0x20) {
                a = Array(s[..<sp])
                b = Array(s[(sp + 1)...])
            } else {
                throw GemmaTokenizerError.badFormat
            }
            guard let ia = vocab[a], let ib = vocab[b], let inew = vocab[a + b] else { continue }
            let key = UInt64(UInt32(bitPattern: ia)) << 32 | UInt64(UInt32(bitPattern: ib))
            if merges[key] == nil { merges[key] = Merge(rank: Int32(rank), newID: inew) }
        }
        var byteTokens = [Int32](repeating: -1, count: 256)
        for b in 0..<256 { byteTokens[b] = vocab[Array(String(format: "<0x%02X>", b).utf8)] ?? -1 }
        var added: [Added] = []
        var first = Set<UInt8>()
        if let at = root.get("added_tokens")?.array {
            for t in at {
                guard case .str(let c)? = t.get("content"), let id = t.get("id")?.int, !c.isEmpty else { continue }
                // All Gemma added tokens are special with normalized == false: they are matched in the raw text.
                added.append(Added(bytes: c, id: Int32(id)))
                first.insert(c[0])
            }
            added.sort { $0.bytes.count > $1.bytes.count }
        }
        func id(_ s: String) -> Int32 { vocab[Array(s.utf8)] ?? -1 }
        bosID = id("<bos>")
        eosID = id("<eos>")
        padID = id("<pad>")
        unkID = id("<unk>")
        guard bosID >= 0, eosID >= 0, unkID >= 0 else { throw GemmaTokenizerError.badFormat }
        self.vocab = vocab
        self.merges = merges
        self.byteTokens = byteTokens
        self.added = added
        addedFirst = first
    }

    /// Token ids without bos and eos, and without truncation.
    public func encodeBody(_ text: String) -> [Int32] {
        var out: [Int32] = []
        let u = Array(text.utf8)
        var segStart = 0, i = 0
        while i < u.count {
            if addedFirst.contains(u[i]) {
                var hit: Added?
                for t in added where t.bytes.count <= u.count - i && u[i] == t.bytes[0] {
                    if u[i..<(i + t.bytes.count)].elementsEqual(t.bytes) { hit = t; break }
                }
                if let h = hit {
                    if segStart < i { out += bpe(u[segStart..<i]) }
                    out.append(h.id)
                    i += h.bytes.count
                    segStart = i
                    continue
                }
            }
            i += 1
        }
        if segStart < u.count { out += bpe(u[segStart..<u.count]) }
        return out
    }

    /// Token ids of text that must never produce a control token: no added special token is matched, so a transcript line that
    /// contains `<turn|>` is ordinary text. Control tokens enter a prompt only through the chat template builder.
    public func encodeLiteral(_ text: String) -> [Int32] {
        let u = Array(text.utf8)
        return u.isEmpty ? [] : bpe(u[0..<u.count])
    }

    /// Whether `id` is an added special token (a control token or a placeholder): never part of generated text.
    public func isControl(_ id: Int32) -> Bool { decoder.table(vocab: vocab, added: added, byteTokens: byteTokens).control[Int(id)] }

    /// The vocabulary size (ids are 0..<vocabularySize).
    public var vocabularySize: Int { decoder.table(vocab: vocab, added: added, byteTokens: byteTokens).bytes.count }

    /// The bytes a token stands for in text: "▁" is a space, `<0xNN>` is the single byte NN. Control tokens give an empty array.
    public func tokenBytes(_ id: Int32) -> [UInt8] {
        let t = decoder.table(vocab: vocab, added: added, byteTokens: byteTokens)
        guard id >= 0, Int(id) < t.bytes.count else { return [] }
        return t.bytes[Int(id)]
    }

    /// All tokens' bytes (index = id), for grammar masks.
    public var allTokenBytes: [[UInt8]] { decoder.table(vocab: vocab, added: added, byteTokens: byteTokens).bytes }

    /// The text bytes of `ids` (control tokens skipped). Incomplete UTF-8 stays as bytes: use `StreamingDecoder` to print.
    public func decode(_ ids: [Int32]) -> [UInt8] { ids.flatMap { tokenBytes($0) } }

    /// The number of tokens of `prefix + text` without bos and eos.
    public func count(_ text: String, prefix: String = "") -> Int { encodeBody(prefix + text).count }

    /// bos, the tokens of `prefix + text` (the tail is cut so that the whole is at most `maxTokens`) and eos, like
    /// `tokenizer(text, truncation=True, max_length=maxTokens)`. `truncated` tells whether the tail was cut.
    public func encode(_ text: String, prefix: String = "", maxTokens: Int = 512) -> (ids: [Int32], truncated: Bool) {
        var body = encodeBody(prefix + text)
        let room = max(0, maxTokens - 2)
        let truncated = body.count > room
        if truncated { body.removeLast(body.count - room) }
        return ([bosID] + body + [eosID], truncated)
    }

    // MARK: BPE

    private func bpe(_ seg: ArraySlice<UInt8>) -> [Int32] {
        var norm: [UInt8] = []
        norm.reserveCapacity(seg.count + 16)
        for b in seg {
            if b == 0x20 { norm += Self.space } else { norm.append(b) }
        }
        // Initial symbols: one per unicode scalar (vocab id, else byte fallback).
        var ids: [Int32] = []
        ids.reserveCapacity(norm.count)
        var i = 0
        while i < norm.count {
            let b0 = norm[i]
            let len = b0 < 0x80 ? 1 : b0 < 0xE0 ? 2 : b0 < 0xF0 ? 3 : 4
            let end = min(i + len, norm.count)
            let ch = Array(norm[i..<end])
            if let id = vocab[ch] {
                ids.append(id)
            } else {
                var tmp: [Int32] = []
                for b in ch {
                    let t = byteTokens[Int(b)]
                    if t < 0 { tmp = []; break }
                    tmp.append(t)
                }
                if tmp.isEmpty { if ids.last != unkID { ids.append(unkID) } } else { ids += tmp }  // fuse_unk
            }
            i = end
        }
        if ids.count < 2 { return ids }
        // Merge by rank (lowest first), leftmost first: a doubly linked list and a heap, as in Hugging Face tokenizers.
        let n = ids.count
        var prev = (0..<n).map { Int32($0) - 1 }
        var next = (0..<n).map { Int32($0) + 1 }
        next[n - 1] = -1
        var alive = [Bool](repeating: true, count: n)
        var heap = Heap()
        func key(_ a: Int32, _ b: Int32) -> UInt64 { UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b)) }
        for p in 0..<(n - 1) {
            if let m = merges[key(ids[p], ids[p + 1])] { heap.push(rank: m.rank, pos: Int32(p), newID: m.newID) }
        }
        while let top = heap.pop() {
            let p = Int(top.pos)
            if !alive[p] { continue }
            let q = Int(next[p])
            if q < 0 { continue }
            guard let m = merges[key(ids[p], ids[q])], m.newID == top.newID else { continue }
            ids[p] = top.newID
            alive[q] = false
            let r = next[q]
            next[p] = r
            if r >= 0 { prev[Int(r)] = Int32(p) }
            if r >= 0, let mm = merges[key(ids[p], ids[Int(r)])] { heap.push(rank: mm.rank, pos: Int32(p), newID: mm.newID) }
            let l = prev[p]
            if l >= 0, let mm = merges[key(ids[Int(l)], ids[p])] { heap.push(rank: mm.rank, pos: l, newID: mm.newID) }
        }
        var out: [Int32] = []
        var p: Int32 = 0
        while p >= 0 && Int(p) < n {
            out.append(ids[Int(p)])
            p = next[Int(p)]
        }
        return out
    }

    /// id -> bytes, built on first use (the search model never needs it).
    private final class DecoderTable: @unchecked Sendable {
        struct Table {
            var bytes: [[UInt8]]
            var control: [Bool]
        }

        private let lock = NSLock()
        private var cached: Table?

        func table(vocab: [[UInt8]: Int32], added: [Added], byteTokens: [Int32]) -> Table {
            lock.lock(); defer { lock.unlock() }
            if let cached { return cached }
            let size = Int(vocab.values.max() ?? -1) + 1
            var bytes = [[UInt8]](repeating: [], count: size)
            var control = [Bool](repeating: false, count: size)
            var isByte = [Int32: UInt8]()
            for (b, id) in byteTokens.enumerated() where id >= 0 { isByte[id] = UInt8(b) }
            for (k, id) in vocab {
                if let b = isByte[id] { bytes[Int(id)] = [b]; continue }
                var out: [UInt8] = []
                out.reserveCapacity(k.count)
                var i = 0
                while i < k.count {
                    if i + 2 < k.count, k[i] == 0xE2, k[i + 1] == 0x96, k[i + 2] == 0x81 { out.append(0x20); i += 3 } else { out.append(k[i]); i += 1 }
                }
                bytes[Int(id)] = out
            }
            for a in added where Int(a.id) < size {
                control[Int(a.id)] = true
                bytes[Int(a.id)] = []
            }
            let t = Table(bytes: bytes, control: control)
            cached = t
            return t
        }
    }

    private struct Heap {
        struct Element {
            var rank: Int32
            var pos: Int32
            var newID: Int32
        }

        var a: [Element] = []

        @inline(__always) static func less(_ x: Element, _ y: Element) -> Bool { x.rank != y.rank ? x.rank < y.rank : x.pos < y.pos }

        mutating func push(rank: Int32, pos: Int32, newID: Int32) {
            a.append(Element(rank: rank, pos: pos, newID: newID))
            var i = a.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if Self.less(a[i], a[p]) { a.swapAt(i, p); i = p } else { break }
            }
        }

        mutating func pop() -> Element? {
            guard !a.isEmpty else { return nil }
            let top = a[0]
            let last = a.removeLast()
            if !a.isEmpty {
                a[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < a.count && Self.less(a[l], a[m]) { m = l }
                    if r < a.count && Self.less(a[r], a[m]) { m = r }
                    if m == i { break }
                    a.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
    }
}
