// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The lines of the Me channel that are the other participants' voice picked up by the microphone (speakers instead of
/// headphones), found from the finished transcript of both channels. The microphone hears the remote voice a little after
/// the system audio carries it (the room, and up to a few hundred milliseconds more over Bluetooth), and the transcriber
/// writes it again, a little worse, as if the user had said it. The minutes treat Me as the user, so an echo becomes the
/// user's words and the user's tasks.
///
/// A Me line is an echo when the Others lines it overlaps in time say the same:
/// - most of its words (`words`) and of its pairs of consecutive words (`pairs`) are in them: an interjection during a
///   monologue shares a few words with it, rarely their order;
/// - it lies within them in time (`covered`), allowing for the delay: a user who repeats what was just said starts after it;
/// - it does not say their words before they do (`maxLead`): when a participant on speakers sends the user's voice back, the
///   Others line is the echo, heard after the user, and the user's line is what was said;
/// - it has at least `minWords` words that carry meaning: "okay", "yes, exactly" are never marked.
///
/// The other way round (`farEchoes`): a participant on speakers whose call app doesn't cancel the echo sends the user's voice back,
/// a call's round trip later, and the transcriber writes it in Others as if they had said it. An Others line is that echo when most
/// of its words and pairs are in the Me lines it overlaps, it lies within them allowing for the trip, and it says their words at
/// least `minLag` after the user did: a line that says them sooner is the original that the user's microphone picked up.
///
/// Nothing is removed: the lines found are marked, and the person can take a mark back.
public enum EchoDetection {
    public struct Line: Sendable, Equatable {
        public let id: Int64
        public let channel: Channel
        public let start: Double
        public let end: Double
        public let text: String

        public init(id: Int64, channel: Channel, start: Double, end: Double, text: String) {
            self.id = id
            self.channel = channel
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// The release thresholds come from `llm-eval --tasks echo` on the 24 public DEV meetings (846 replays, 162,560 simulated echo
    /// lines, 63,720 of the participants' own lines): 90.7 % of the echo lines' words found, 0.30 % of the own lines (0.11 % of
    /// their words) marked. With the far side sending every own line back, 2.2 % of them are marked (33.8 % with no `maxLead`).
    /// The first guess (3 words, pairs 0.4) found 92.9 % of the echo words but marked 0.64 % of the own lines.
    public struct Settings: Sendable, Equatable {
        /// How much later the microphone may hear the remote voice than the system audio carries it, in seconds.
        public var maxDelay = 0.5
        /// Words that carry meaning (stopwords left out) a Me line needs before it can be an echo.
        public var minWords = 4
        /// Share of the Me line's words, and of its pairs of consecutive words, found in the Others lines it overlaps.
        public var words = 0.6
        public var pairs = 0.3
        /// Share of the Me line's time within the Others lines it overlaps (each one extended by `maxDelay`). The sweep found
        /// little difference between 0.5 and 0.8 on simulated echoes, whose timing is exact; real ones are cut less exactly.
        public var covered = 0.6
        /// How much earlier a Me line may say the Others lines' words than they do, in seconds: an echo is heard after what it
        /// repeats, and the far side's echo of the user about a call's round trip after the user. Allows for the transcriber's
        /// timing.
        public var maxLead = 0.15

        public init() {}
    }

    /// The ids of the Me lines that are echoes, in the order of `lines`.
    public static func echoes(_ lines: [Line], locale: String, settings: Settings = Settings()) -> [Int64] {
        evidence(lines, locale: locale, maxDelay: settings.maxDelay).filter { $0.isEcho(settings) }.map(\.id)
    }

    /// The far side's echo of the user, in Others (see the type's description). The thresholds are the speakers' echo's: on the 24
    /// public DEV meetings (`llm-eval --tasks echo`, every own line sent back 0.25 or 0.5 s later with 20 % of its words changed) they
    /// find 80.8 % of the echo's words (61.7 % of its lines) and mark 0.05 % of the others' own lines where the participant's speakers
    /// echo them (110 of 207,675) and 2 of 46,150 with the far side's echo. The best of the sweep at most 0.5 % found 84.6 % of the
    /// words for 0.10 % (3 words, pairs 0.2, covered 0.8). Without the rule on matched edges, 0.24 % of the others' lines were marked.
    public struct FarSettings: Sendable, Equatable {
        /// How much later than the user the far side's echo may be heard: the call there and back, with the far side's speakers.
        public var maxDelay = 1.0
        /// How much later than the user it must be heard: sooner, the Others line is the original and the Me line the echo.
        public var minLag = 0.15
        public var minWords = 4
        public var words = 0.6
        public var pairs = 0.3
        public var covered = 0.6

        public init() {}

        /// The lag must come from edges the two lines share: the start of the first line still being said (`Evidence.lag` without
        /// one) is often the speakers' echo of the line before, which would make an original look sent back.
        func admits(_ e: Evidence) -> Bool {
            e.words >= minWords && e.wordShare >= words && e.pairShare >= pairs && e.covered >= covered && e.edgesMatched
                && e.lag >= minLag && e.lag <= maxDelay
        }
    }

    /// The ids of the Others lines that are the user's voice sent back by the far side, in the order of `lines`.
    public static func farEchoes(_ lines: [Line], locale: String, settings: FarSettings = FarSettings()) -> [Int64] {
        evidence(lines, locale: locale, maxDelay: settings.maxDelay, judging: .others).filter { settings.admits($0) }.map(\.id)
    }

    /// What decides whether a Me line is an echo, measured once (the evaluation sweeps the thresholds over it).
    struct Evidence: Sendable, Equatable {
        let id: Int64
        let words: Int
        let wordShare: Double
        let pairShare: Double
        let covered: Double
        /// How much later the line starts or ends than the line of the other channel that starts or ends with the same words (the
        /// mean of the two); without one, how much later it starts than the first line it overlaps that had not ended by then.
        /// Negative when it is earlier.
        let lag: Double
        /// `lag` comes from an edge both lines share, not from the first line still being said.
        let edgesMatched: Bool
        /// How much earlier it is (0 when it is later).
        var lead: Double { max(0, -lag) }

        func isEcho(_ s: Settings) -> Bool {
            words >= s.minWords && wordShare >= s.words && pairShare >= s.pairs && covered >= s.covered && lead <= s.maxLead
        }
    }

    /// The evidence of every line of `judging` (Me: the speakers' echo; Others: the far side's) that overlaps a line of the other
    /// channel, in the order of `lines`.
    static func evidence(_ lines: [Line], locale: String, maxDelay: Double, judging channel: Channel = .me) -> [Evidence] {
        let profile = LanguageProfile(identifier: locale)
        let source = lines.filter { $0.channel != channel }.map { Said($0, locale: locale, profile: profile) }
        guard !source.isEmpty else { return [] }
        var out: [Evidence] = []
        for line in lines where line.channel == channel {
            let heard = source.filter { $0.line.start <= line.end && $0.line.end + maxDelay >= line.start }
            guard !heard.isEmpty else { continue }
            let said = Said(line, locale: locale, profile: profile)
            let words = Set(heard.flatMap(\.words)), pairs = Set(heard.flatMap(\.pairs))
            let lag = lag(of: said, behind: heard)
            out.append(Evidence(id: line.id, words: said.words.count, wordShare: share(said.words, in: words), pairShare: share(said.pairs, in: pairs),
                                covered: coverage(of: line, by: heard.map { ($0.line.start, $0.line.end + maxDelay) }),
                                lag: lag.value, edgesMatched: lag.matched))
        }
        return out
    }

    /// A line's words that carry meaning and its pairs of consecutive words (every word counts for the pairs), with the first
    /// and last two pairs in order.
    private struct Said {
        let line: Line
        let words: Set<String>
        let pairs: Set<String>
        let head: [String]
        let tail: [String]

        init(_ line: Line, locale: String, profile: LanguageProfile) {
            self.line = line
            words = QuestionDedup.keys(line.text, locale: locale)
            let tokens = TextKeys.tokens(line.text, profile: profile).map(\.norm)
            let ordered = zip(tokens, tokens.dropFirst()).map { "\($0) \($1)" }
            pairs = Set(ordered)
            head = Array(ordered.prefix(2))
            tail = Array(ordered.suffix(2).reversed())
        }
    }

    /// How much later `me` starts or ends than the line of `heard` that starts or ends with the same words, the nearest one,
    /// as the mean of the two. Without either, how much later it starts than the first line still being said then. Both lines
    /// are the same speech, so their edges are the same words: no word times to estimate, and a line cut differently has
    /// only the edge they share.
    private static func lag(of me: Said, behind heard: [Said]) -> (value: Double, matched: Bool) {
        func edge(_ pairs: KeyPath<Said, [String]>, _ time: KeyPath<Line, Double>) -> Double? {
            heard.filter { o in zip(me[keyPath: pairs], o[keyPath: pairs]).contains { $0 == $1 } }
                .map { me.line[keyPath: time] - $0.line[keyPath: time] }
                .min { abs($0) < abs($1) }
        }
        let lags = [edge(\.head, \.start), edge(\.tail, \.end)].compactMap { $0 }
        if !lags.isEmpty { return (lags.reduce(0, +) / Double(lags.count), true) }
        // A line that ended before this one started can only be repeated, never sent back after it.
        let first = heard.filter { $0.line.end > me.line.start }.map(\.line.start).min()
        return (me.line.start - (first ?? me.line.start), false)
    }

    private static func share(_ part: Set<String>, in whole: Set<String>) -> Double {
        part.isEmpty ? 0 : Double(part.intersection(whole).count) / Double(part.count)
    }

    /// The share of the line's time inside the union of `spans`; for a line with no length, whether it is inside one.
    static func coverage(of line: Line, by spans: [(start: Double, end: Double)]) -> Double {
        let length = line.end - line.start
        guard length > 0 else { return spans.contains { $0.start <= line.start && line.start <= $0.end } ? 1 : 0 }
        var covered = 0.0, reached = line.start
        for span in spans.sorted(by: { $0.start < $1.start }) {
            let from = max(span.start, reached), to = min(span.end, line.end)
            if to > from { covered += to - from; reached = to }
        }
        return covered / length
    }
}
