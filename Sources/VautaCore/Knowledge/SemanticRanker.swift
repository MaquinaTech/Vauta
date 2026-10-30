// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// How Ask and the search fields rank passages: pure rules, with no database and no model. `MeetingStore.retrieve` and
/// `DocumentIndex.search` call them.
///
/// With the search model installed and its vectors covering the corpus, the cosine to the question ranks (`semantic`). Keyword
/// search (BM25) only boosts exact matches of codes and rare names, which a model cannot be trusted to copy. Without the model,
/// while the corpus is not covered yet, or with a model server's vectors, the previous behaviour stays (`keyword`, `rrf`).
/// The numbers come from spike 9c (docs/SEARCH_MODEL.md) and were measured on synthetic data; they are constants in one place so
/// a failed held-out check can switch the name part off (`nameBoost = 0`).
public enum SemanticRanker {
    // MARK: Parameters

    /// Added to the cosine of a candidate that contains every code of the question.
    public static let codeBoost = 0.30
    /// Added, times the fraction of the question's names found, to a candidate that contains at least one.
    public static let nameBoost = 0.15
    /// Exact matches taken as candidates per item.
    public static let candidatesPerItem = 40
    /// A name is rare when it appears in at most `max(nameDocumentFrequency, N / 20000)` rows.
    public static let nameDocumentFrequency = 3
    /// The lowest cosine at which a passage counts as related to a text (related meetings and documents, the sidebar's "By
    /// meaning" group). Measured on the vectors of spike 9b (256 dimensions, int8): two unrelated texts have a cosine of about
    /// 0.53 on average and 0.64 at the 99th percentile, so a floor of 0.65 removes the noise of random pairs while keeping 95%
    /// of the best relevant passages of the monolingual sets (5th percentile 0.69 to 0.77; 0.63 across languages). It cannot tell
    /// "nothing relates" from "something does" by itself: the best passage of a large unrelated corpus reaches 0.67 to 0.72.
    public static let relatedFloor: Float = 0.65
    /// Backlog tolerated in steady state: at most this many items, or this share of the corpus, may lack a vector.
    public static let toleratedMissing = 50
    public static let toleratedShare = 0.02

    // MARK: Mode

    public enum Mode: Sendable, Equatable {
        /// BM25 and the graph, as before (no vectors, or the model is not ready).
        case keyword
        /// BM25 and vectors fused with RRF (k = 60): a model server's embeddings, whose model was not measured.
        case rrf
        /// The search model ranks; keywords only boost exact matches.
        case semantic
    }

    public struct Coverage: Sendable, Equatable {
        /// Items that have a vector or a marker (see `VectorIndex.unembeddableMarker`): everything the model has looked at.
        public var covered: Int
        public var total: Int
        /// Of the covered items, how many the model could not embed (stored as markers; they never get a vector).
        public var skipped: Int
        public init(covered: Int, total: Int, skipped: Int = 0) {
            self.covered = covered
            self.total = total
            self.skipped = skipped
        }
        public var missing: Int { max(0, total - covered) }
        public var isComplete: Bool { missing == 0 }
        public var fraction: Double { total == 0 ? 1 : Double(covered) / Double(total) }
    }

    /// Whether `model` (a `chunks.model` / `passage_vectors.model` value) is the search model's space.
    public static func isSearchModelSpace(_ model: String) -> Bool { model.hasPrefix("embeddinggemma-2@") }

    /// The ranking for one kind of content (meetings or documents), decided separately for each.
    /// - `space`: the space of the question's vector (nil: not embedded).
    /// - `coverage`: how much of the content has vectors in that space.
    /// - `reachedBefore`: complete coverage was reached once in this space (sticky until the recipe changes).
    /// - `scopeCovered`: for a search inside one meeting or a filter of documents, whether that scope is fully covered.
    public static func mode(space: EmbeddingSpace?, coverage: Coverage, reachedBefore: Bool, scopeCovered: Bool? = nil) -> Mode {
        guard let space else { return .keyword }
        guard isSearchModelSpace(space.model) else { return .rrf }
        if let scopeCovered { return scopeCovered ? .semantic : .keyword }
        guard coverage.total > 0 else { return .keyword }
        if coverage.isComplete { return .semantic }
        let tolerated = coverage.missing <= toleratedMissing || Double(coverage.missing) <= toleratedShare * Double(coverage.total)
        return reachedBefore && tolerated ? .semantic : .keyword
    }

    // MARK: Exact items

    private static let codePattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9]+(?:[-#/_.][A-Za-z0-9]+)+|\b[A-Za-z]*\d[A-Za-z0-9]*\b"#)

    /// Dates ("2026-10-12", "12/10/2026", "12/10", "2026-10"), and numbers and versions written with dots only ("1.2.3", "500.00",
    /// "1.500.000"), are not codes: they would put +0.30 on any passage that has the same digits, whatever it says. A letter, "#" or
    /// "_" makes an item a code again ("v1.2.3", "INV-2026-10-12", "CASE#12").
    private static let notACode: NSRegularExpression = {
        let day = #"(?:0?[1-9]|[12]\d|3[01])"#, month = #"(?:0?[1-9]|1[0-2])"#, sep = #"[-/.]"#
        let forms = [
            #"\d{4}\#(sep)\#(month)\#(sep)\#(day)"#,        // 2026-10-12
            #"\#(day)\#(sep)\#(month)\#(sep)(?:\d{4}|\d{2})"#,  // 12/10/2026, 12.10.26
            #"\d{4}[-/]\#(month)"#,                          // 2026-10
            #"\#(day)[-/]\#(month)"#,                        // 12/10
            #"\d+(?:\.\d+)+"#,                              // 1.2.3, 500.00, 1.500.000
        ]
        return try! NSRegularExpression(pattern: "^(?:" + forms.joined(separator: "|") + ")$")
    }()

    static func isDateOrNumber(_ item: String) -> Bool {
        notACode.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)) != nil
    }

    /// Code-like items of a question: ticket numbers, invoice ids, references. Mixed letters and digits of at least four
    /// characters ("PO-48213", "CASE#000123", "A100"), digits with a separator of at least five ("0123/45"), or six or more
    /// digits. Not "Q3", "A4", "2026", dates, versions or amounts.
    public static func codes(in question: String) -> [String] {
        let range = NSRange(question.startIndex..., in: question)
        var seen = Set<String>()
        var out: [String] = []
        for match in codePattern.matches(in: question, range: range) {
            guard let r = Range(match.range, in: question) else { continue }
            let item = String(question[r])
            let hasDigit = item.contains(where: \.isNumber)
            let hasLetter = item.unicodeScalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
            let hasSeparator = item.contains { "-#/_.".contains($0) }
            let keep = (hasDigit && hasLetter && item.count >= 4) || (hasDigit && hasSeparator && item.count >= 5)
                || (hasDigit && !hasLetter && item.count >= 6)
            if keep, !isDateOrNumber(item), seen.insert(item.lowercased()).inserted { out.append(item) }
        }
        return out
    }

    /// Words that open a question or a request ("What", "Wer", "Dime", "Quel") and articles: capitalised only because they start a
    /// sentence, never a name. Lower case, the languages the app is translated into that use spaces.
    static let sentenceStarters: Set<String> = [
        "what", "when", "where", "who", "whom", "whose", "why", "which", "how", "did", "does", "do", "is", "are", "was", "were", "can",
        "could", "will", "would", "should", "tell", "show", "find", "list", "give", "summarize", "summarise", "explain", "any", "the",
        "and", "but", "for", "from", "with", "about", "has", "have", "had", "there", "this", "that", "these", "those", "please",
        "qué", "que", "cuándo", "cuando", "dónde", "donde", "quién", "quien", "quiénes", "quienes", "cuál", "cual", "cuáles", "cuales",
        "cuánto", "cuanto", "cuántos", "cuantos", "cómo", "como", "por", "para", "hay", "dime", "cuéntame", "resume", "explica", "busca",
        "muestra", "los", "las", "una", "uno", "del", "con", "sobre",
        "was", "wann", "wer", "wem", "wen", "wie", "warum", "wieso", "weshalb", "welche", "welcher", "welches", "wo", "wohin", "gibt", "hat",
        "haben", "ist", "sind", "kann", "zeige", "zeig", "erkläre", "fasse", "finde", "der", "die", "das", "ein", "eine", "und", "mit",
        "über", "für", "gib", "nenne",
        "quel", "quelle", "quels", "quelles", "quand", "où", "qui", "quoi", "comment", "pourquoi", "combien", "est", "sont", "dis",
        "montre", "résume", "explique", "trouve", "les", "des", "une", "dans", "avec", "pour", "sur",
        "cosa", "che", "quando", "dove", "chi", "quale", "quali", "come", "perché", "perche", "quanto", "quanti", "sono", "dimmi",
        "mostra", "riassumi", "spiega", "trova", "gli", "uno", "con", "per", "sul", "nel",
        "quem", "qual", "quais", "onde", "quantos", "existe", "diga", "mostre", "resuma", "explique", "encontre", "uma", "com",
    ]

    /// Words of a question that may be rare proper names: capitalised (not all capitals) with at least three letters, or the one
    /// word of a one-word query. A word that opens a sentence is capitalised for that reason alone, so it counts only when it is not
    /// a question or request word ("What did Ana say" has the one candidate "Ana"; "Ana, what did she say" has "Ana" too). Whether
    /// they are rare is decided by the caller from the index. Empty for text in scripts without spaces: the keyword index does
    /// not segment it.
    public static func nameCandidates(in question: String, excluding codes: [String]) -> [String] {
        if question.contains(where: { TextKeys.isNoSpaceScript($0) }) { return [] }
        let codeTokens = Set(codes.flatMap { phraseTokens($0) })
        // Words with whether each opens a sentence (the start, or after . ? ! ¿ ¡ …).
        var words: [(text: String, opens: Bool)] = []
        var current = ""
        var opens = true
        var nextOpens = true
        for ch in question {
            if ch.isLetter || ch.isNumber {
                if current.isEmpty { opens = nextOpens }
                current.append(ch)
            } else {
                if !current.isEmpty { words.append((current, opens)); current = ""; nextOpens = false }
                if ".?!¿¡…\n".contains(ch) { nextOpens = true }
            }
        }
        if !current.isEmpty { words.append((current, opens)) }
        var seen = Set<String>()
        var out: [String] = []
        for (w, opensSentence) in words {
            let lower = w.lowercased()
            guard !w.contains(where: \.isNumber), !codeTokens.contains(lower), w.count >= 3 else { continue }
            if opensSentence, words.count > 1, sentenceStarters.contains(lower) { continue }
            let capitalised = w.first?.isUppercase == true && w != w.uppercased()
            if (capitalised || words.count == 1), seen.insert(lower).inserted { out.append(w) }
        }
        return out
    }

    /// The words of an item as the keyword index splits them.
    static func phraseTokens(_ item: String) -> [String] {
        item.split { !($0.isLetter || $0.isNumber) }.map { String($0).lowercased() }
    }

    /// An FTS5 phrase for an item: its words in order, adjacent ("PO-48213" is `"po 48213"`), so "PO-482130" does not match.
    /// nil when the item has no words.
    public static func phrase(_ item: String) -> String? {
        let tokens = phraseTokens(item)
        return tokens.isEmpty ? nil : "\"" + tokens.joined(separator: " ").replacingOccurrences(of: "\"", with: "") + "\""
    }

    /// The most rows a name may appear in to count as rare, in a corpus of `rows` rows.
    public static func rareLimit(rows: Int) -> Int { max(nameDocumentFrequency, (rows + 19_999) / 20_000) }

    // MARK: Scores

    /// The boost of a candidate. `codesMatched` counts the question's code items it contains; every one is required.
    public static func boost(codesMatched: Int, codesTotal: Int, namesMatched: Int, namesTotal: Int) -> Double {
        var b = 0.0
        if codesTotal > 0, codesMatched == codesTotal { b += codeBoost }
        if namesTotal > 0, namesMatched > 0 { b += nameBoost * Double(namesMatched) / Double(namesTotal) }
        return b
    }

    /// A keyword-only candidate (it has no vector yet) at keyword rank `rank` gets the cosine of the vector hit at the same rank,
    /// so a just-recorded meeting stays findable without letting BM25 decide the order.
    public static func pseudoScore(rank: Int, vectorScores: [Float]) -> Double {
        guard !vectorScores.isEmpty else { return 0 }
        return Double(vectorScores[min(rank, vectorScores.count - 1)])
    }

    /// The passages related to a text by meaning, in their order, at most `limit`: those whose own cosine reaches `relatedFloor`.
    /// The boosts of exact codes and names order them but never let one in (the keyword results already show exact matches), and
    /// a passage that holds a placeholder score (no vector yet) has no cosine.
    public static func related<P>(_ passages: [P], cosine: (P) -> Double?, limit: Int) -> [P] {
        Array(passages.filter { (cosine($0) ?? 0) >= Double(relatedFloor) }.prefix(limit))
    }

    /// Highest score first; ties by key, so the order is deterministic.
    public static func order<K: Comparable & Hashable>(_ scores: [K: Double]) -> [(key: K, score: Double)] {
        scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value) }
    }
}
