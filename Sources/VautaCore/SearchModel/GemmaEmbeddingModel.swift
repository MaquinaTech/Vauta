// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Accelerate
import Foundation

/// The search model as an `EmbeddingModel`: one model for every language, 256 dimensions, prompts for queries and documents.
///
/// A query longer than the sequence limit is cut (queries are capped at 400 characters by their callers). A document text
/// longer than the limit is split into windows at sentence, else whitespace, boundaries without overlap; each window is
/// embedded and the stored vector is the token-weighted mean of the window vectors, renormalised. The model mean-pools before
/// a linear projection, so this closely approximates a long-context embedding.
public struct GemmaEmbeddingModel: EmbeddingModel, ChunkBudgeting {
    public static let space = EmbeddingSpace(model: SearchModelManifest.spaceModel, dimensions: SearchModelManifest.dimensions)

    let engine: SearchModelEngine

    init(engine: SearchModelEngine) { self.engine = engine }

    public func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
        guard !texts.isEmpty else { return EmbeddingBatch(vectors: [], space: Self.space) }
        let dims = SearchModelManifest.dimensions
        if purpose == .query {
            let raw = try await engine.embed(texts, purpose: .query)
            return EmbeddingBatch(vectors: raw.map { $0.isEmpty ? [Float](repeating: 0, count: dims) : $0 }, space: Self.space)
        }
        let budget = try await engine.bodyBudget(purpose: .document)
        let counts = try await engine.tokenCounts(texts, purpose: .document)
        let promptTokens = SearchModelManifest.maxSequence - 2 - budget
        // Windows for every text, embedded in one request so the engine can batch them.
        var windows: [String] = []
        var spans: [Range<Int>] = []
        for (text, count) in zip(texts, counts) {
            let pieces = count - promptTokens <= budget ? [text] : try await Self.split(text, budget: budget, engine: engine)
            spans.append(windows.count..<(windows.count + pieces.count))
            windows += pieces
        }
        let windowCounts = windows.count == texts.count ? counts : try await engine.tokenCounts(windows, purpose: .document)
        let vectors = try await engine.embed(windows, purpose: .document)
        var out: [[Float]] = []
        for span in spans {
            out.append(Self.combine(span.map { (vectors[$0], windowCounts[$0]) }, dims: dims))
        }
        return EmbeddingBatch(vectors: out, space: Self.space)
    }

    /// Meeting chunks must fit the sequence limit: the budget is the body budget minus a margin for merges across the newline
    /// between lines and the cut of a window (their token counts are summed line by line).
    public func chunkBudget() async throws -> ChunkBudget {
        let tokenizer = try await engine.planningTokenizer()
        let body = try await engine.bodyBudget(purpose: .document)
        return ChunkBudget(limit: max(32, body - 8)) { tokenizer.count($0) }
    }

    /// The token-weighted mean of window vectors, renormalised. A window that could not be embedded (empty vector) makes the
    /// whole text unembeddable (a zero vector), so a half-embedded passage is never stored.
    static func combine(_ parts: [(vector: [Float], tokens: Int)], dims: Int) -> [Float] {
        guard !parts.isEmpty, parts.allSatisfy({ $0.vector.count == dims }) else { return [Float](repeating: 0, count: dims) }
        if parts.count == 1 { return parts[0].vector }
        var sum = [Float](repeating: 0, count: dims)
        for p in parts { vDSP.add(sum, vDSP.multiply(Float(max(1, p.tokens)), p.vector), result: &sum) }
        let norm = sqrt(vDSP.sumOfSquares(sum))
        guard norm > 0, norm.isFinite else { return [Float](repeating: 0, count: dims) }
        return vDSP.divide(sum, norm)
    }

    /// Splits `text` into windows that each fit `budget` body tokens: whole sentences while they fit, a sentence that does not
    /// fit by words, a word that does not fit by characters. Pieces are counted on their own; BPE merges across a boundary
    /// are rare, and the engine cuts the tail of a window that still is too long.
    static func split(_ text: String, budget: Int, engine: SearchModelEngine) async throws -> [String] {
        var units: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, enclosing, _ in
            units.append(String(text[enclosing]))
            _ = range
        }
        if units.isEmpty { units = [text] }
        var windows: [String] = []
        var current = ""
        var currentTokens = 0
        let counts = try await engine.tokenCounts(units, purpose: .document)
        let promptTokens = try await engine.tokenCounts([""], purpose: .document)[0]
        for (unit, raw) in zip(units, counts) {
            let n = max(0, raw - promptTokens)
            if n > budget {
                if !current.isEmpty { windows.append(current); current = ""; currentTokens = 0 }
                windows += try await splitWords(unit, budget: budget, engine: engine, promptTokens: promptTokens)
            } else if currentTokens + n > budget {
                windows.append(current)
                current = unit
                currentTokens = n
            } else {
                current += unit
                currentTokens += n
            }
        }
        if !current.isEmpty { windows.append(current) }
        return windows.filter { !$0.allSatisfy(\.isWhitespace) }
    }

    private static func splitWords(_ text: String, budget: Int, engine: SearchModelEngine, promptTokens: Int) async throws -> [String] {
        var words: [String] = []
        var word = ""
        for ch in text {
            word.append(ch)
            if ch.isWhitespace { words.append(word); word = "" }
        }
        if !word.isEmpty { words.append(word) }
        let counts = try await engine.tokenCounts(words, purpose: .document)
        var windows: [String] = []
        var current = ""
        var currentTokens = 0
        for (w, raw) in zip(words, counts) {
            let n = max(1, raw - promptTokens)
            if n > budget {
                // One word longer than a window (an unbroken run of text): cut by characters, about budget tokens each.
                if !current.isEmpty { windows.append(current); current = ""; currentTokens = 0 }
                let size = max(1, w.count * budget / n)
                var rest = Substring(w)
                while !rest.isEmpty {
                    windows.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
            } else if currentTokens + n > budget {
                windows.append(current)
                current = w
                currentTokens = n
            } else {
                current += w
                currentTokens += n
            }
        }
        if !current.isEmpty { windows.append(current) }
        return windows
    }
}
