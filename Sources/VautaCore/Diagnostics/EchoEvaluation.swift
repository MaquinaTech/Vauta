// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// `llm-eval --tasks echo --sets <transcripts> --out <dir> [--seed n]`: `EchoDetection` on simulated echoes, with no audio and
/// no model. Each public meeting is replayed once per participant (one with at least 20 lines) as "Me", their headset; the other
/// participants are "Others", and the speakers' echo of every Others line is added to the Me channel the way a transcriber
/// would write it:
/// - 0.15 s or 0.4 s later (the room; Bluetooth);
/// - with words dropped or replaced by another word of the meeting at 10, 20 or 30 %;
/// - cut differently: two lines in a row sometimes heard as one, a long line sometimes cut in two.
///
/// An echo that would fall on the participant's own speech is left out (the transcriber would write one line of both). The
/// participant's own lines are what must never be marked: in meetings people do repeat each other's words.
///
/// Writes `echo/sweep.tsv`, one row per setting: the share of echo lines found (overall, per condition, and weighted by their
/// words, the plan's measure) and the share of the participant's own lines and words marked. Prints the settings that mark at
/// most 0.5 % of the own lines, most echo words found first, and the release setting.
enum EchoEvaluation {
    static let errorRates = [0.1, 0.2, 0.3]
    static let delays = [0.15, 0.4]
    static let maxOwnMarked = 0.005

    private struct Passage: Decodable {
        let id: Int64
        let text: String
        let start: Double?
        let end: Double?
        let speaker: String?
    }

    private struct File: Decodable {
        let passages: [Passage]
        let language: String?
    }

    /// The evidence of one replay: the echo lines and the participant's own lines, with how many of each there were.
    struct Replay {
        var condition: Int
        var echoes: [EchoDetection.Evidence] = []
        var own: [EchoDetection.Evidence] = []
        /// The words of each line in `echoes` and `own`, by id, and the words of all of them.
        var words: [Int64: Int] = [:]
        var echoLines = 0
        var ownLines = 0
        var echoWords = 0
        var ownWords = 0
    }

    struct Score: Equatable {
        let settings: EchoDetection.Settings
        let recall: Double
        /// The share of the echo lines' words that are in a line found: the plan's measure (an echo of "okay" matters less).
        let wordRecall: Double
        let ownMarked: Int
        let ownLines: Int
        /// The share of the participant's own words hidden.
        let ownWordsMarked: Double
        let recallByCondition: [Double]
        var ownMarkedRate: Double { ownLines == 0 ? 0 : Double(ownMarked) / Double(ownLines) }
    }

    static func run(_ o: LLMEvaluation.Options, log: @Sendable (String) -> Void) throws {
        var replays: [Replay] = []
        var files = LLMEvaluation.setFiles(o)
        if let m = o.maxItems { files = Array(files.prefix(m)) }
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path), let meeting = try? JSONDecoder().decode(File.self, from: data) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let locale = meeting.language == "es" || name.hasPrefix("es_") ? "es-ES" : "en-US"
            replays += self.replays(meeting.passages, name: name, locale: locale, seed: o.seed)
        }
        let scores = sweep(replays)
        let dir = o.out.appendingPathComponent("echo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try table(scores).write(to: dir.appendingPathComponent("sweep.tsv"), atomically: true, encoding: .utf8)
        let echoLines = replays.reduce(0) { $0 + $1.echoLines }, ownLines = replays.reduce(0) { $0 + $1.ownLines }
        log("echo: \(files.count) meetings, \(replays.count) replays, \(echoLines) echo lines, \(ownLines) own lines")
        for s in best(scores).prefix(10) { log("echo: " + line(s)) }
        if let release = scores.first(where: { $0.settings == EchoDetection.Settings() }) { log("echo: release " + line(release)) }
    }

    /// The replays of one meeting: each participant with at least 20 lines as Me, in every condition.
    private static func replays(_ passages: [Passage], name: String, locale: String, seed: UInt64) -> [Replay] {
        let timed = passages.compactMap { p -> EchoDetection.Line? in
            guard let start = p.start, p.speaker != nil, !p.text.isEmpty else { return nil }
            return EchoDetection.Line(id: p.id, channel: .others, start: start, end: max(p.end ?? start, start), text: p.text)
        }
        let speakerOf = Dictionary(passages.compactMap { p in p.speaker.map { (p.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let vocabulary = timed.flatMap { $0.text.split(separator: " ").map(String.init) }
        var counts: [String: Int] = [:]
        for line in timed { counts[speakerOf[line.id] ?? "", default: 0] += 1 }
        var out: [Replay] = []
        for speaker in counts.keys.sorted() where counts[speaker, default: 0] >= 20 {
            let own = timed.filter { speakerOf[$0.id] == speaker }.map { EchoDetection.Line(id: $0.id, channel: .me, start: $0.start, end: $0.end, text: $0.text) }
            let others = timed.filter { speakerOf[$0.id] != speaker }.sorted { $0.start < $1.start }
            for (condition, (rate, delay)) in conditions.enumerated() {
                var rng = Generator(seed: seed ^ fnv(name) ^ fnv(speaker) &+ UInt64(condition))
                let echoes = simulatedEchoes(of: others, avoiding: own, rate: rate, delay: delay, vocabulary: vocabulary, rng: &rng)
                let echoIDs = Set(echoes.map(\.id)), ownIDs = Set(own.map(\.id))
                let words = Dictionary((echoes + own).map { ($0.id, $0.text.split(separator: " ").count) }, uniquingKeysWith: { a, _ in a })
                var replay = Replay(condition: condition, words: words, echoLines: echoes.count, ownLines: own.count,
                                    echoWords: echoes.reduce(0) { $0 + (words[$1.id] ?? 0) }, ownWords: own.reduce(0) { $0 + (words[$1.id] ?? 0) })
                for e in EchoDetection.evidence((others + own + echoes).sorted { $0.start < $1.start }, locale: locale, maxDelay: EchoDetection.Settings().maxDelay) {
                    if echoIDs.contains(e.id) { replay.echoes.append(e) } else if ownIDs.contains(e.id) { replay.own.append(e) }
                }
                out.append(replay)
            }
        }
        return out
    }

    static var conditions: [(rate: Double, delay: Double)] { errorRates.flatMap { r in delays.map { (r, $0) } } }

    /// The Me lines the speakers' echo of `others` would leave, with ids above every passage's.
    static func simulatedEchoes(of others: [EchoDetection.Line], avoiding own: [EchoDetection.Line], rate: Double, delay: Double,
                                vocabulary: [String], rng: inout Generator) -> [EchoDetection.Line] {
        var out: [EchoDetection.Line] = []
        var next: Int64 = 1_000_000_000
        var i = 0
        while i < others.count {
            var group = [others[i]]
            if i + 1 < others.count, others[i + 1].start - others[i].end < 1, rng.chance(0.25) { group.append(others[i + 1]); i += 1 }
            i += 1
            let words = group.flatMap { $0.text.split(separator: " ").map(String.init) }.compactMap { word -> String? in
                let u = rng.unit()
                if u < rate / 2 { return nil }
                if u < rate, !vocabulary.isEmpty { return vocabulary[rng.index(vocabulary.count)] }
                return word
            }
            guard !words.isEmpty else { continue }
            let start = group[0].start + delay, end = group[group.count - 1].end + delay
            var pieces = [(start: start, end: end, words: words)]
            if end - start > 6, words.count >= 6, rng.chance(0.2) {
                let cut = words.count / 2, at = start + (end - start) * Double(cut) / Double(words.count)
                pieces = [(start, at, Array(words[..<cut])), (at, end, Array(words[cut...]))]
            }
            for p in pieces {
                // The transcriber would write the participant's speech and the echo as one line.
                guard !own.contains(where: { min($0.end, p.end) - max($0.start, p.start) > 0.3 }) else { continue }
                out.append(EchoDetection.Line(id: next, channel: .me, start: p.start, end: p.end, text: p.words.joined(separator: " ")))
                next += 1
            }
        }
        return out
    }

    /// Every setting of the grid, scored over all replays.
    static func sweep(_ replays: [Replay]) -> [Score] {
        var scores: [Score] = []
        for words in [0.5, 0.6, 0.7, 0.8] {
            for pairs in [0.2, 0.3, 0.4, 0.5] {
                for covered in [0.5, 0.6, 0.8] {
                    for minWords in [3, 4, 5] {
                        var s = EchoDetection.Settings()
                        (s.words, s.pairs, s.covered, s.minWords) = (words, pairs, covered, minWords)
                        scores.append(score(s, replays))
                    }
                }
            }
        }
        return scores
    }

    static func score(_ s: EchoDetection.Settings, _ replays: [Replay]) -> Score {
        var found = Array(repeating: 0, count: conditions.count), total = Array(repeating: 0, count: conditions.count)
        var ownMarked = 0, ownLines = 0, wordsFound = 0, echoWords = 0, ownWordsMarked = 0, ownWords = 0
        for r in replays {
            let foundHere = r.echoes.filter { $0.isEcho(s) }, markedHere = r.own.filter { $0.isEcho(s) }
            found[r.condition] += foundHere.count
            total[r.condition] += r.echoLines
            ownMarked += markedHere.count
            ownLines += r.ownLines
            wordsFound += foundHere.reduce(0) { $0 + (r.words[$1.id] ?? 0) }
            echoWords += r.echoWords
            ownWordsMarked += markedHere.reduce(0) { $0 + (r.words[$1.id] ?? 0) }
            ownWords += r.ownWords
        }
        let all = total.reduce(0, +)
        func rate(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
        return Score(settings: s, recall: rate(found.reduce(0, +), all), wordRecall: rate(wordsFound, echoWords), ownMarked: ownMarked,
                     ownLines: ownLines, ownWordsMarked: rate(ownWordsMarked, ownWords),
                     recallByCondition: zip(found, total).map { rate($0, $1) })
    }

    /// The settings that mark at most `maxOwnMarked` of the own lines, most echo words found first (fewer own lines marked on a tie).
    static func best(_ scores: [Score]) -> [Score] {
        scores.filter { $0.ownMarkedRate <= maxOwnMarked }
            .sorted { $0.wordRecall == $1.wordRecall ? $0.ownMarked < $1.ownMarked : $0.wordRecall > $1.wordRecall }
    }

    private static func line(_ s: Score) -> String {
        String(format: "words %.1f pairs %.1f covered %.1f min %d: recall %.3f (words %.3f), own marked %d of %d (%.2f %%, words %.2f %%)",
               s.settings.words, s.settings.pairs, s.settings.covered, s.settings.minWords, s.recall, s.wordRecall, s.ownMarked, s.ownLines,
               s.ownMarkedRate * 100, s.ownWordsMarked * 100)
    }

    private static func table(_ scores: [Score]) -> String {
        let byCondition = conditions.map { String(format: "recall_err%02.0f_delay%03.0f", $0.rate * 100, $0.delay * 1000) }
        var rows = [(["words", "pairs", "covered", "min_words", "recall", "word_recall", "own_marked", "own_lines", "own_marked_rate", "own_words_marked_rate"]
                     + byCondition).joined(separator: "\t")]
        for s in scores {
            rows.append(([String(s.settings.words), String(s.settings.pairs), String(s.settings.covered), String(s.settings.minWords),
                          String(format: "%.4f", s.recall), String(format: "%.4f", s.wordRecall), String(s.ownMarked), String(s.ownLines),
                          String(format: "%.5f", s.ownMarkedRate), String(format: "%.5f", s.ownWordsMarked)]
                         + s.recallByCondition.map { String(format: "%.4f", $0) }).joined(separator: "\t"))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// FNV-1a: the same seed for a name in every run (Swift's `hashValue` changes from one process to the next).
    static func fnv(_ s: String) -> UInt64 {
        s.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }

    /// SplitMix64: the same sequence for the same seed, so a replay is the same in every run.
    struct Generator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }

        /// In [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
        mutating func index(_ count: Int) -> Int { Int(next() % UInt64(count)) }
    }
}
