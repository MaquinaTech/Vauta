// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// A passage retrieved for Ask: a stretch of one meeting with its segments.
public struct RetrievedPassage: Sendable, Identifiable, Hashable {
    public var id: String { "\(meeting.id):\(Int(start))" }
    public let meeting: MeetingStore.Meeting
    public let start: Double
    public let end: Double
    public let segments: [CitableSegment]
    public var score: Double
    /// The cosine of the question to the passage's chunk alone, without the keyword and graph boosts (nil unless the search model
    /// ranked it). The live-answer gate compares this one, not `score`.
    public var cosine: Double?

    public init(meeting: MeetingStore.Meeting, start: Double, end: Double, segments: [CitableSegment], score: Double, cosine: Double? = nil) {
        self.meeting = meeting
        self.start = start
        self.end = end
        self.segments = segments
        self.score = score
        self.cosine = cosine
    }

    /// The distinct speakers of the passage, in order of appearance (empty without speaker data).
    public var speakers: [SpeakerTag] {
        var seen = Set<Int64>()
        return segments.compactMap(\.speaker).filter { tag in tag.id.map { seen.insert($0).inserted } ?? true }
    }
}

/// How many tokens a chunk may hold in the search model's space. The model reads at most 512 tokens, and a meeting chunk of
/// 130 s is longer than that in Spanish, German and French (spike 9b), so the tail would be cut and never searchable.
public struct ChunkBudget: Sendable {
    /// Tokens available for the chunk's text.
    public let limit: Int
    /// The tokens of a text (without bos, eos or prompt).
    public let count: @Sendable (String) -> Int

    public init(limit: Int, count: @escaping @Sendable (String) -> Int) {
        self.limit = limit
        self.count = count
    }
}

extension MeetingStore {
    static let chunkTarget: Double = 100
    static let chunkMax: Double = 130

    // MARK: Chunks for embeddings (text is not duplicated: time ranges)

    /// Windows of ~100 s (at most 130 s) overlapping by one segment.
    /// Each line starts with who said it: the speaker's name when the user named them and
    /// the assignment is sure, else "Me" / "Others". Never a guess, a score or a voice.
    /// With a `budget` (the search model's space) a window also stops growing when the next line would not fit the model's
    /// sequence limit, so every chunk is embedded whole. A single line over the budget is its own chunk and the encoder cuts its
    /// tail (ASR segments are under 30 s, so this is rare). Without a budget the plan is the one server spaces use.
    ///
    /// `upToSegment`: only the lines saved up to that segment id (a meeting being recorded, as it stood when a question was asked).
    public func chunkPlan(_ meetingID: Int64, names: Bool = true, budget: ChunkBudget? = nil,
                          upToSegment: Int64? = nil) throws -> [(start: Double, end: Double, text: String)] {
        var segs = try citableSegments(meetingID)
        if let upToSegment { segs = segs.filter { $0.id <= upToSegment } }
        var out: [(Double, Double, String)] = []
        var lines: [Int: String] = [:]
        var tokens: [Int: Int] = [:]
        func line(_ k: Int) -> String {
            if let l = lines[k] { return l }
            let l = "\(Self.chunkLabel(segs[k], names: names)): \(segs[k].text)"
            lines[k] = l
            return l
        }
        func lineTokens(_ k: Int, _ budget: ChunkBudget) -> Int {
            if let t = tokens[k] { return t }
            let t = budget.count(line(k))
            tokens[k] = t
            return t
        }
        var i = 0
        while i < segs.count {
            var j = i
            var end = segs[i].start
            var used = 0
            while j < segs.count, segs[j].start - segs[i].start < Self.chunkTarget || j == i {
                if let budget {
                    // The newline between two lines is a token too.
                    let cost = lineTokens(j, budget) + (j > i ? 1 : 0)
                    if j > i, used + cost > budget.limit { break }
                    used += cost
                }
                end = max(end, segs[j].start + 1)
                j += 1
                if j < segs.count, segs[j].start - segs[i].start >= Self.chunkMax { break }
            }
            out.append((segs[i].start, end, (i..<j).map(line).joined(separator: "\n")))
            if j >= segs.count { break }
            i = max(i + 1, j - 1)   // one segment of overlap
        }
        return out
    }

    /// The speaker label inside a chunk's text.
    static func chunkLabel(_ s: CitableSegment, names: Bool = true) -> String {
        guard names, let tag = s.speaker, !tag.isLowConfidence, !tag.overlap, let raw = tag.name else { return s.channel.promptLabel }
        let name = PromptText.clip(SingleLineText.flatten(raw), 40)
        return name.isEmpty || isSelfPronoun(TextKeys.norm(name)) ? s.channel.promptLabel : name
    }

    /// A fingerprint of the text a chunk is embedded from (see migration 17).
    public static func textKey(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a meeting's stored chunks were embedded from other text than the transcript gives today: its
    /// speakers were named, renamed or separated again since. Chunks written before speakers existed (no
    /// `text_key`) are left alone when the text they were made from is the text the plan gives now (no speaker is
    /// named): their keys are filled in, and nothing is embedded again.
    public func chunksOutOfDate(_ meetingID: Int64, budget: ChunkBudget? = nil) async throws -> Bool {
        let stored = try db.query("SELECT text_key FROM chunks WHERE meeting_id = ? ORDER BY start", [.integer(meetingID)]).map { $0.string(0) }
        guard !stored.isEmpty else { return false }
        let hasSpeakers = try !db.query("SELECT 1 FROM meeting_speakers WHERE meeting_id = ? LIMIT 1", [.integer(meetingID)]).isEmpty
        guard hasSpeakers || stored.contains(where: { !$0.isEmpty }) else { return false }
        let plan = try chunkPlan(meetingID, budget: budget)
        let expected = plan.map { Self.textKey($0.text) }
        if stored == expected { return false }
        if stored.allSatisfy(\.isEmpty), stored.count == plan.count,
           try chunkPlan(meetingID, names: false, budget: budget).map(\.text) == plan.map(\.text) {
            // Legacy chunks made from this very text: adopt the keys instead of embedding the meeting again.
            let starts = try db.query("SELECT id FROM chunks WHERE meeting_id = ? ORDER BY start", [.integer(meetingID)]).map { $0.int(0) }
            try transaction {
                for (id, key) in zip(starts, expected) { try run("UPDATE chunks SET text_key = ? WHERE id = ?", [.text(key), .integer(id)]) }
            }
            try await commitEdit()
            return false
        }
        return true
    }

    /// Meetings that have speaker rows: the only ones whose chunk text can depend on a name.
    public func meetingsWithSpeakers() throws -> Set<Int64> {
        Set(try db.query("SELECT DISTINCT meeting_id FROM meeting_speakers").map { $0.int(0) })
    }

    /// Replaces a meeting's chunks with vectors of one embedding space
    /// (`chunks.model` and `chunks.dims` record it). `key`: `textKey` of the text that was embedded.
    public func replaceChunks(_ meetingID: Int64, _ items: [(start: Double, end: Double, q: Data, scale: Float, key: String)],
                              space: EmbeddingSpace) async throws {
        try transaction {
            try run("DELETE FROM chunks WHERE meeting_id = ?", [.integer(meetingID)])
            for c in items where c.q.count == space.dimensions {
                try run("INSERT INTO chunks(meeting_id, start, end, model, dims, scale, emb, text_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        [.integer(meetingID), .real(c.start), .real(c.end), .text(space.model), .integer(Int64(space.dimensions)),
                         .real(Double(c.scale)), .blob(c.q), .text(c.key)])
            }
        }
        vectorCache = nil
        try await commitEdit()
    }

    /// Deletes every chunk of the spaces whose model starts with `prefix` (the search model was removed).
    public func dropChunks(modelPrefix prefix: String) async throws {
        try transaction { try run("DELETE FROM chunks WHERE substr(model, 1, ?) = ?", [.integer(Int64(prefix.count)), .text(prefix)]) }
        vectorCache = nil
        try await commitEdit()
    }

    public func hasChunks(_ meetingID: Int64) throws -> Bool {
        try !db.query("SELECT 1 FROM chunks WHERE meeting_id = ? LIMIT 1", [.integer(meetingID)]).isEmpty
    }

    /// In-memory index of one embedding space (rebuilt when the chunks change).
    func vectorIndex(space: EmbeddingSpace) throws -> VectorIndex {
        let key = "\(space.model)\u{1F}\(space.dimensions)"
        if let cached = vectorCache, cached.model == key { return cached.index }
        let dims = space.dimensions
        let rows = try db.query("SELECT id, scale, emb FROM chunks WHERE model = ? AND dims = ? ORDER BY id",
                                [.text(space.model), .integer(Int64(dims))])
        let buffer = SecretBuffer(capacity: rows.count * dims)
        var ids: [Int64] = [], scales: [Float] = []
        for r in rows {
            let emb = r.data(2)
            guard emb.count == dims, dims > 0, Float(r.double(1)) > VectorIndex.unembeddableScale else { continue }
            emb.withUnsafeBytes { (buffer.base + buffer.count).copyMemory(from: $0.baseAddress!, byteCount: dims) }
            buffer.count += dims
            ids.append(r.int(0))
            scales.append(Float(r.double(1)))
        }
        let index = VectorIndex(dims: dims, ids: ids, scales: scales, buffer: buffer)
        vectorCache = (key, index)
        return index
    }

    /// The vector candidates of a search, best first: the index's top `k`, or with a `scope` the top `k` of those meetings' own
    /// chunks, each scored (a top K of the whole library would leave them out when other meetings on the same topic fill it).
    func vectorCandidates(_ index: VectorIndex, _ query: [Float], k: Int, scope: [Int64]?, space: EmbeddingSpace) throws -> [(id: Int64, score: Float)] {
        guard let scope else { return index.search(query, k: k) }
        let ids = try db.query("SELECT id FROM chunks WHERE meeting_id IN (SELECT value FROM json_each(?)) AND model = ? AND dims = ?",
                               [.ids(scope), .text(space.model), .integer(Int64(space.dimensions))]).map { $0.int(0) }
        return index.search(query, k: k, among: ids)
    }

    // MARK: Hybrid search

    /// Context entities named in a text (unambiguous exact aliases, deterministic).
    /// `locale`: the text's language; nil detects it (falling back to the legacy language).
    public func entitiesNamed(in text: String, locale: Locale? = nil) throws -> [Int64] {
        let profile = locale.map(LanguageProfile.init(locale:)) ?? LanguageProfile.detecting(text)
        let entries = try db.query("SELECT a.alias_norm, coalesce(e.merged_into, e.id) FROM aliases a JOIN entities e ON e.id = a.entity_id")
            .map { (norm: $0.string(0), value: $0.int(1)) }
        let matcher = NameMatcher(entries, profile: profile)
        let found = matcher.matches(in: text, tokens: TextKeys.tokens(text, profile: profile), profile: profile)
            .compactMap { Set($0.values).count == 1 ? $0.values[0] : nil }
        return Array(Set(found))
    }

    /// The alias keys (normalized) of each context entity named in `text`, one list per entity, for ranking document passages that
    /// name the same people or projects.
    public func entityAliasKeys(named text: String, locale: Locale? = nil) throws -> [[String]] {
        let ids = try entitiesNamed(in: text, locale: locale)
        guard !ids.isEmpty else { return [] }
        var byEntity: [Int64: [String]] = [:]
        for row in try db.query("SELECT coalesce(e.merged_into, e.id), a.alias_norm FROM aliases a JOIN entities e ON e.id = a.entity_id WHERE coalesce(e.merged_into, e.id) IN (SELECT value FROM json_each(?))", [.ids(ids)]) {
            byEntity[row.int(0), default: []].append(row.string(1))
        }
        return ids.sorted().compactMap { byEntity[$0] }
    }

    /// Keyword terms of a question: no function words of its language, and
    /// short words only when they look like acronyms, numbers or names
    /// ("API", "Q3", "Li"). Text in scripts without spaces is segmented.
    static func queryTerms(_ question: String, profile: LanguageProfile) -> [String] {
        let all = significantTerms(question, profile: profile)
        // In Japanese and Chinese the segmenter also yields inflection endings and particles (まし, 做): they
        // are dropped unless nothing else is left, so a question made of such a word still searches.
        let content = all.filter { !isFunctionFragment($0) }
        return content.isEmpty ? all : content
    }

    /// One or two hiragana, or a single Han character: an ending or a particle, rarely a search word.
    private static func isFunctionFragment(_ word: String) -> Bool {
        let scalars = word.unicodeScalars
        if scalars.count <= 2, scalars.allSatisfy({ (0x3040...0x309F).contains($0.value) }) { return true }
        return scalars.count == 1 && scalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
    }

    private static func significantTerms(_ question: String, profile: LanguageProfile) -> [String] {
        var seen = Set<String>()
        return TextKeys.tokens(question, profile: profile).compactMap { token in
            guard !profile.stopwords.contains(token.norm) else { return nil }
            var word = token.original
            if isHangul(word) {
                // Korean attaches particles to nouns ("베타에", "회의는") and most nouns have two syllables.
                // Strip the particle so the prefix match finds every inflected form; keep 2+ syllables.
                word = strippingKoreanParticle(word)
                guard word.count >= 2, seen.insert(word).inserted else { return nil }
                return word
            }
            guard seen.insert(token.norm).inserted else { return nil }
            if word.contains(where: TextKeys.isNoSpaceScript) || word.count >= 3 { return word }
            // Two characters: "Q3", "AI", "Li", "5G"; not "de", "to", "la".
            let looksSpecial = word.contains(where: \.isNumber) || (word.first?.isUppercase ?? false)
            return word.count == 2 && looksSpecial ? word : nil
        }
    }

    /// The words of `text` the keyword search matched for `question`: whole words (never a stretch inside one),
    /// without the question's function words, segmented for languages written without spaces. Korean words
    /// match by prefix, as the search does (the mark covers the matched syllables only). Used to mark the passages Ask shows.
    public static func matchedRanges(of question: String, in text: String) -> [Range<String.Index>] {
        let profile = LanguageProfile.detecting(question)
        let terms = Set(queryTerms(question, profile: profile).map(TextKeys.norm))
        guard !terms.isEmpty else { return [] }
        return TextKeys.tokens(text, profile: profile).compactMap { token in
            if terms.contains(token.norm) { return token.range }
            // A Korean word matches by prefix, but only the matched syllables are marked, not the particle after them
            // ("베타는" marks "베타").
            guard isHangul(token.original),
                  let term = terms.filter({ token.norm.hasPrefix($0) }).max(by: { $0.count < $1.count }),
                  let end = text.index(token.range.lowerBound, offsetBy: term.count, limitedBy: token.range.upperBound)
            else { return nil }
            return token.range.lowerBound..<end
        }
    }

    private static func isHangul(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
    }

    /// Common trailing particles, longest first. Only stripped when two or more syllables remain.
    private static let koreanParticles = ["에서", "으로", "에게", "까지", "부터", "은", "는", "이", "가", "을", "를", "에", "의", "와", "과", "로", "도", "만"]

    static func strippingKoreanParticle(_ word: String) -> String {
        for particle in koreanParticles where word.hasSuffix(particle) && word.count - particle.count >= 2 {
            return String(word.dropLast(particle.count))
        }
        return word
    }

    /// BM25 (FTS5) + vectors (when the question was embedded) fused with RRF
    /// (k = 60), plus a boost when a passage names the question's entities.
    /// Without embeddings (`queryVector == nil`) it works with BM25 + graph.
    /// `space`: the embedding space of `queryVector`; only chunks of that
    /// space are compared (vectors of other models or sizes are never mixed). `within`: only that meeting (long
    /// meetings that do not fit whole). `locale`: the question's language;
    /// nil detects it.
    ///
    /// `mode` says how vectors and keywords combine (see `SemanticRanker`): `.rrf` is the fusion described above (the default,
    /// and what a model server's vectors use), `.keyword` ignores vectors, `.semantic` ranks by the search model's cosine and
    /// uses keywords only to boost exact codes and rare names (`retrieveSemantic`).
    ///
    /// `excluding`: no passage of that meeting (the live answers look in the past meetings while one is recorded: the recording's own
    /// lines would otherwise take the places). It is applied where candidates are found, so the limit counts only other meetings.
    ///
    /// `meetings`: only those meetings (the meetings list's filter), applied the same way; with `within`, that meeting if the filter
    /// has it. Their vectors are scored exactly, as one meeting's are.
    public func retrieve(_ question: String, queryVector: [Float]?, within: Int64? = nil, excluding: Int64? = nil, meetings: [Int64]? = nil,
                         space: EmbeddingSpace? = nil, limit: Int = 8, maxChars: Int = 18_000, locale: Locale? = nil,
                         mode: SemanticRanker.Mode = .rrf, windows: AskWindows? = nil) throws -> [RetrievedPassage] {
        let scope = Self.scope(within: within, meetings: meetings)
        if scope?.isEmpty == true { return [] }
        // The small window's keyword search (`AskHarness.windows`): short windows around the hits. A ranking by meaning keeps the chunks.
        if let windows, mode == .keyword || queryVector == nil {
            return try retrieveWindows(question, scope: scope, excluding: excluding, locale: locale, maxChars: maxChars, windows: windows)
        }
        if mode == .semantic, let queryVector, let space {
            return try retrieveSemantic(question, queryVector: queryVector, scope: scope, excluding: excluding, space: space, limit: limit,
                                        maxChars: maxChars, locale: locale)
        }
        typealias Key = String
        var ranges: [Key: (meeting: Int64, start: Double, end: Double)] = [:]
        var score: [Key: Double] = [:]
        func add(_ key: Key, rank: Int, weight: Double = 1) { score[key, default: 0] += weight / Double(60 + rank) }
        let profile = locale.map(LanguageProfile.init(locale:)) ?? LanguageProfile.detecting(question)

        // Vectors.
        if mode != .keyword, let queryVector, let space {
            let index = try vectorIndex(space: space)
            let top = try vectorCandidates(index, queryVector, k: 50, scope: scope, space: space)
            if !top.isEmpty {
                let rows = try db.query("SELECT id, meeting_id, start, end FROM chunks WHERE id IN (SELECT value FROM json_each(?))", [.ids(top.map(\.id))])
                let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.int(0), ($0.int(1), $0.double(2), $0.double(3))) })
                for (rank, hit) in top.filter({ h in excluding == nil || byID[h.id]?.0 != excluding }).enumerated() {
                    guard let (m, s, e) = byID[hit.id] else { continue }
                    let key = "c\(hit.id)"
                    ranges[key] = (m, s, e)
                    add(key, rank: rank)
                }
            }
        }
        // Keywords over the transcript, OR-ed. The FTS index (unicode61) does
        // not segment Han/Kana/Thai text, so those terms are found by substring.
        let terms = Self.queryTerms(question, profile: profile)
        let spaced = terms.filter { !$0.contains(where: TextKeys.isNoSpaceScript) }
        let unspaced = terms.filter { $0.contains(where: TextKeys.isNoSpaceScript) }
        var keywordHits: [[Row]] = []
        if !spaced.isEmpty {
            let match = spaced.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " OR ")
            keywordHits.append(try db.query("""
                SELECT s.id, s.meeting_id, s.start FROM segments_fts f JOIN segments s ON s.id = f.rowid
                WHERE segments_fts MATCH ?1 AND (?2 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?2))) AND (?3 IS NULL OR s.meeting_id <> ?3) AND \(Self.notEcho) ORDER BY rank LIMIT 80
                """, [.text(match), scope.map { .ids($0) }, excluding.map { .integer($0) }]))
        }
        if !unspaced.isEmpty {
            keywordHits.append(try db.query("""
                SELECT id, meeting_id, start FROM (
                    SELECT s.id, s.meeting_id, s.start, (SELECT COUNT(*) FROM json_each(?1) WHERE instr(s.text, value) > 0) AS found
                    FROM segments s WHERE (?2 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?2))) AND (?3 IS NULL OR s.meeting_id <> ?3) AND \(Self.notEcho))
                WHERE found > 0 ORDER BY found DESC, start LIMIT 80
                """, [.text(Self.json(strings: unspaced)), scope.map { .ids($0) }, excluding.map { .integer($0) }]))
        }
        // A moment goes to the first chunk that holds it, of any space, else to its time bucket.
        func place(_ m: Int64, _ t: Double, in chunk: ChunkSpan?, rank: Int, weight: Double = 1) {
            if m == excluding { return }
            let l = chunk.map { Located(chunk: $0, meeting: m) } ?? Located(bucketOf: t, meeting: m)
            ranges[l.key] = (m, l.start, l.end)
            add(l.key, rank: rank, weight: weight)
        }
        let holding = try chunksHolding(keywordHits.flatMap { $0.map { $0.int(0) } }, space: nil)
        for hits in keywordHits {
            for (rank, h) in hits.enumerated() { place(h.int(1), h.double(2), in: holding[h.int(0)]?.first, rank: rank) }
        }
        // Moments the user flagged: the segments cited by a note (or its expansion) that matches the question rank higher.
        for (rank, moment) in try noteCitedMoments(terms: terms, scope: scope).prefix(40).enumerated() {
            place(moment.meeting, moment.t, in: try chunks(holding: moment.t, in: moment.meeting, space: nil).first, rank: rank, weight: 1.5)
        }
        // The minutes' decisions and tasks, and the kept questions, that match: the moments they cite are candidates too.
        for (rank, moment) in try itemCitedMoments(terms: terms, scope: scope).enumerated() {
            place(moment.meeting, moment.t, in: try chunks(holding: moment.t, in: moment.meeting, space: nil).first, rank: rank, weight: itemKeyWeight)
        }
        // Graph: passages that name the people or projects of the question, and (for "What did Ana say about X") passages where a
        // speaker the user named Ana talks.
        let entities = try entitiesNamed(in: question, locale: profile.locale)
        if !entities.isEmpty {
            // Where the transcript misheard one of them (`misheardMoments`): a candidate as a keyword hit is, at half the weight while
            // the correction is open.
            let misheard = try misheardMoments(of: entities, scope: scope, excluding: excluding)
            let holdingMisheard = try chunksHolding(misheard.map(\.segment), space: nil)
            for (rank, m) in misheard.enumerated() {
                place(m.meeting, m.t, in: holdingMisheard[m.segment]?.first, rank: rank, weight: m.confirmed ? 1 : 0.5)
            }
            for (key, signal) in try graphSignals(ranges, entities: entities) {
                if signal.named > 0 { add(key, rank: 0, weight: Double(signal.named)) }
                if signal.said { add(key, rank: 0, weight: 1.5) }
            }
        }
        return try assemble(Array(score), ranges: ranges, limit: limit, maxChars: maxChars)
    }

    /// The meetings a search may use (nil: all): `within` alone, the `meetings` of a filter, or both (that meeting if the filter has it).
    static func scope(within: Int64?, meetings: [Int64]?) -> [Int64]? {
        guard let within else { return meetings }
        guard let meetings else { return [within] }
        return meetings.contains(within) ? [within] : []
    }

    /// The best passages, without overlaps and within the budget. `ranked` is (key, score) in any order.
    func assemble(_ ranked: [(key: String, value: Double)], ranges: [String: (meeting: Int64, start: Double, end: Double)],
                  limit: Int, maxChars: Int, cosine: [String: Double] = [:]) throws -> [RetrievedPassage] {
        let score = Dictionary(ranked, uniquingKeysWith: { a, _ in a })
        var out: [RetrievedPassage] = []
        var chars = 0
        for (key, s) in score.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            guard out.count < limit, let r = ranges[key] else { break }
            if out.contains(where: { $0.meeting.id == r.meeting && $0.start < r.end && r.start < $0.end }) { continue }
            let segs = try db.query("""
                SELECT s.id, s.speaker, s.start, s.text, \(Self.speakerColumns) FROM segments s \(Self.speakerJoins)
                WHERE s.meeting_id = ? AND s.start >= ? AND s.start <= ? AND \(Self.notEcho) ORDER BY s.start, s.id
                """, [.integer(r.meeting), .real(r.start - 0.5), .real(r.end)]).map(Self.citable)
            let size = segs.reduce(0) { $0 + $1.text.count + 24 }
            guard !segs.isEmpty, chars + size <= maxChars,
                  let meeting = try self.meeting(r.meeting)
            else { continue }
            chars += size
            out.append(RetrievedPassage(meeting: meeting, start: r.start, end: r.end, segments: segs, score: s, cosine: cosine[key]))
        }
        return out
    }
}
