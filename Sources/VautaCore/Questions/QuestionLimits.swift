// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import NaturalLanguage

/// The numbers of the live answers' rate limits and windows (the design's section 3.3 and 4.6). Times are in seconds.
public struct QuestionTiming: Sendable, Equatable {
    /// S2: how long a candidate waits for the lines that follow.
    public var settle = 4.0
    /// S5: at most one call per `checkInterval`, and `checkMax` per `checkWindow`.
    public var checkInterval = 10.0
    public var checkWindow = 600.0
    public var checkMax = 20
    /// The search model's embedding of a heard question (about a second of GPU): at most `embedMax` per `checkWindow`, the rest use
    /// keywords. Twice the checks, because many candidates never reach the check.
    public var embedMax = 40
    /// S5 queue: two waiting, the newest wins, nothing older than `staleAfter` is checked.
    public var queueCapacity = 2
    public var staleAfter = 45.0
    /// Cards: one per `cardInterval` (`cardIntervalLowPower` in Low Power Mode) and `cardMax` per `cardWindow`.
    public var cardInterval = 45.0
    public var cardIntervalLowPower = 180.0
    public var cardWindow = 600.0
    public var cardMax = 6
    /// A finished answer waits at most this long for the card budget.
    public var cardWaitMax = 30.0
    /// How long an answer is expected to take: the card budget is looked at for the moment it would be ready, and an answer that could
    /// not be shown by then is not started.
    public var expectedAnswerSeconds = 6.0
    /// A card shown later than `lateAfter` after the question says when it was asked; later than `dropAfter` it is not shown.
    public var lateAfter = 45.0
    public var dropAfter = 120.0
    /// A heard question whose answer the person's own question pushed out is asked again once if it arrived less than this long ago.
    public var requeueWithin = 60.0
    /// Duplicate memory.
    public var dedupWindow = 600.0
    public var jaccard = 0.6
    public var cosine = 0.85
    /// The lines around the candidate that the model check reads.
    public var linesBefore = 3
    /// The settle waits for this many lines after the question or for `settle` seconds.
    public var linesAfter = 2
    /// The lines after the question that the check reads: the check starts later than the settle (it waits in a queue and for the rate
    /// limit), so it reads the ones that arrived meanwhile, up to this many.
    public var checkLinesAfter = 3
    /// An answer in flight may finish after the recording stops if it started less than this long ago.
    public var finishAfterStop = 20.0

    public init() {}
}

/// The limits on model work: S5 checks and cards. A value type driven by explicit times, so tests and the replay of the evaluation
/// use a simulated clock.
public struct QuestionLimiter: Sendable {
    public let timing: QuestionTiming
    private var checks: [Double] = []
    private var cards: [Double] = []
    private var embeds: [Double] = []

    public init(timing: QuestionTiming = QuestionTiming()) { self.timing = timing }

    /// Seconds until the next model check may start (0 = now).
    public func checkWait(now: Double) -> Double {
        var wait = 0.0
        if let last = checks.last { wait = max(wait, last + timing.checkInterval - now) }
        let window = checks.filter { $0 > now - timing.checkWindow }
        if window.count >= timing.checkMax, let oldest = window.first { wait = max(wait, oldest + timing.checkWindow - now) }
        return max(0, wait)
    }

    public mutating func recordCheck(now: Double) {
        checks.append(now)
        checks.removeAll { $0 <= now - timing.checkWindow }
    }

    /// Whether the search model may embed one more question now.
    public func embedAllowed(now: Double) -> Bool {
        embeds.filter { $0 > now - timing.checkWindow }.count < timing.embedMax
    }

    public mutating func recordEmbed(now: Double) {
        embeds.append(now)
        embeds.removeAll { $0 <= now - timing.checkWindow }
    }

    /// Seconds until a new card may be shown (0 = now).
    public func cardWait(now: Double, lowPowerMode: Bool) -> Double {
        var wait = 0.0
        if let last = cards.last { wait = max(wait, last + (lowPowerMode ? timing.cardIntervalLowPower : timing.cardInterval) - now) }
        let window = cards.filter { $0 > now - timing.cardWindow }
        if window.count >= timing.cardMax, let oldest = window.first { wait = max(wait, oldest + timing.cardWindow - now) }
        return max(0, wait)
    }

    public mutating func recordCard(now: Double) {
        cards.append(now)
        cards.removeAll { $0 <= now - timing.cardWindow }
    }

    public var checkCount: Int { checks.count }
    public var cardCount: Int { cards.count }
}

/// What to do with an answer that is ready, by how long after the question it is.
public enum QuestionStaleness: Sendable, Equatable {
    case fresh
    /// Shown, with "For the question at …".
    case late
    /// Not shown: stored only.
    case dropped

    public static func classify(age: Double, timing: QuestionTiming) -> QuestionStaleness {
        age > timing.dropAfter ? .dropped : age > timing.lateAfter ? .late : .fresh
    }
}

/// A short queue where the newest wins: when it is full the oldest leaves, and what is older than `staleAfter` is never handed out.
public struct QuestionQueue<Item: Sendable>: Sendable {
    public struct Entry: Sendable {
        public let item: Item
        public let at: Double
    }

    private var entries: [Entry] = []
    public let capacity: Int
    public let staleAfter: Double

    public init(capacity: Int, staleAfter: Double) {
        self.capacity = capacity
        self.staleAfter = staleAfter
    }

    /// Adds an item; returns the ones that left to make room.
    @discardableResult
    public mutating func push(_ item: Item, at: Double) -> [Item] {
        entries.append(Entry(item: item, at: at))
        var dropped: [Item] = []
        while entries.count > max(1, capacity) { dropped.append(entries.removeFirst().item) }
        return dropped
    }

    /// The oldest entry that is not stale (the stale ones before it are dropped and returned too).
    public mutating func pop(now: Double) -> (item: Item?, stale: [Item]) {
        var stale: [Item] = []
        while let first = entries.first, now - first.at > staleAfter { stale.append(entries.removeFirst().item) }
        return (entries.isEmpty ? nil : entries.removeFirst().item, stale)
    }

    /// Like `pop`, but the first entry stays in line (the stale ones before it are still dropped and returned).
    public mutating func peek(now: Double) -> (item: Item?, stale: [Item]) {
        var stale: [Item] = []
        while let first = entries.first, now - first.at > staleAfter { stale.append(entries.removeFirst().item) }
        return (entries.first?.item, stale)
    }

    /// Takes out the entries `predicate` says yes to and returns them.
    public mutating func remove(where predicate: (Item) -> Bool) -> [Item] {
        let gone = entries.filter { predicate($0.item) }.map(\.item)
        entries.removeAll { predicate($0.item) }
        return gone
    }

    public mutating func removeAll() -> [Item] {
        defer { entries.removeAll() }
        return entries.map(\.item)
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    /// The arrival time of the oldest entry.
    public var peekAt: Double? { entries.first?.at }
}

/// Questions heard or typed in the last minutes, to avoid answering the same one twice (S3).
public struct QuestionDedup: Sendable {
    private struct Memory { let keys: Set<String>; let vector: [Float]?; let at: Double }
    private var memory: [Memory] = []
    public let timing: QuestionTiming

    public init(timing: QuestionTiming = QuestionTiming()) { self.timing = timing }

    /// The content words of a question, folded: its stopwords are gone. Words of the scripts written without spaces are taken as
    /// character pairs, which is what two phrasings of the same Japanese or Chinese question share.
    public static func keys(_ text: String, locale: String) -> Set<String> {
        let profile = LanguageProfile(identifier: locale)
        var out = Set<String>()
        for token in TextKeys.tokens(text, profile: profile) where !profile.stopwords.contains(token.norm) {
            if token.norm.contains(where: { TextKeys.isNoSpaceScript($0) }) {
                let chars = Array(token.norm)
                if chars.count <= 2 { out.insert(token.norm) } else { for i in 0..<(chars.count - 1) { out.insert(String(chars[i...(i + 1)])) } }
            } else if token.norm.count > 1 || token.norm.contains(where: \.isNumber) {
                out.insert(token.norm)
            }
        }
        return out
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? Double(dot / (na.squareRoot() * nb.squareRoot())) : 0
    }

    public func isDuplicate(text: String, vector: [Float]? = nil, locale: String, now: Double) -> Bool {
        let keys = Self.keys(text, locale: locale)
        for item in memory where now - item.at <= timing.dedupWindow {
            if Self.jaccard(keys, item.keys) >= timing.jaccard { return true }
            if let vector, let other = item.vector, Self.cosine(vector, other) >= timing.cosine { return true }
        }
        return false
    }

    /// Takes back the latest memory of this text (a question that was remembered before its evidence was fetched, and then failed).
    public mutating func forget(text: String, locale: String) {
        let keys = Self.keys(text, locale: locale)
        if let i = memory.lastIndex(where: { $0.keys == keys }) { memory.remove(at: i) }
    }

    public mutating func remember(text: String, vector: [Float]? = nil, locale: String, now: Double) {
        memory.append(Memory(keys: Self.keys(text, locale: locale), vector: vector, at: now))
        memory.removeAll { now - $0.at > timing.dedupWindow }
    }
}
