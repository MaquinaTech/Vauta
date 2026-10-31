// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// `llm-eval --tasks echo --sets <transcripts> --out <dir> [--seed n]`: `EchoDetection` on simulated echoes, with no audio and
/// no model. Each public meeting is replayed once per participant (one with at least 20 lines) as "Me", their headset; the other
/// participants are "Others", and the speakers' echo of every Others line is added to the Me channel the way a transcriber
/// would write it:
/// - 0.03 s, 0.15 s or 0.4 s later (the Mac's own speakers; other speakers across the room; Bluetooth);
/// - with words dropped or replaced by another word of the meeting at 10, 20 or 30 %;
/// - cut differently: two lines in a row sometimes heard as one, a long line sometimes cut in two, and every start and end
///   moved by up to `jitter` (the transcriber's timing).
///
/// An echo that would fall on the participant's own speech is left out (the transcriber would write one line of both). The
/// participant's own lines are what must never be marked: in meetings people do repeat each other's words. They are also
/// replayed with the far side's echo: a participant on speakers whose call app doesn't cancel it sends the user's voice back
/// into Others, `farDelays` later.
///
/// Writes `echo/sweep.tsv`, one row per setting: the share of echo lines found (overall, per condition, and weighted by their
/// words, the plan's measure) and the share of the participant's own lines and words marked, without and with the far side's
/// echo. Prints the settings that mark at most 0.5 % of the own lines, most echo words found first, and the release setting.
/// The far side's echo is the worst case (every own line sent back), so it is a measure, not a limit.
enum EchoEvaluation {
    static let errorRates = [0.1, 0.2, 0.3]
    static let delays = [0.03, 0.15, 0.4]
    static let jitter = 0.1
    /// The call there and back, with the far side's speakers and microphone.
    static let farDelays = [0.25, 0.5]
    static let farErrorRate = 0.2
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
        /// A replay with the far side's echo of the participant (`farDelays[condition]`) and no echoes in Me.
        var farSide = false
        var echoes: [EchoDetection.Evidence] = []
        var own: [EchoDetection.Evidence] = []
        /// The words of each line in `echoes` and `own`, by id, and the words of all of them.
        var words: [Int64: Int] = [:]
        var echoLines = 0
        var ownLines = 0
        var echoWords = 0
        var ownWords = 0
        /// Judged as Others (`farEchoes`): the far side's echoes of the participant (only with the far side's echo) and the other
        /// participants' own lines, which must never be marked.
        var backs: [EchoDetection.Evidence] = []
        var othersOwn: [EchoDetection.Evidence] = []
        var backLines = 0
        var backWords = 0
        var othersLines = 0
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
        /// The own lines marked, and their number, in the replays with the far side's echo.
        let farMarked: Int
        let farLines: Int
        var ownMarkedRate: Double { ownLines == 0 ? 0 : Double(ownMarked) / Double(ownLines) }
        var farMarkedRate: Double { farLines == 0 ? 0 : Double(farMarked) / Double(farLines) }
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
        let near = replays.filter { !$0.farSide }
        let echoLines = near.reduce(0) { $0 + $1.echoLines }, ownLines = near.reduce(0) { $0 + $1.ownLines }
        log("echo: \(files.count) meetings, \(near.count) replays and \(replays.count - near.count) with the far side's echo, \(echoLines) echo lines, \(ownLines) own lines")
        for s in best(scores).prefix(10) { log("echo: " + line(s)) }
        if let release = scores.first(where: { $0.settings == EchoDetection.Settings() }) { log("echo: release " + line(release)) }
        let far = EchoFarSweep.sweep(replays)
        try EchoFarSweep.table(far).write(to: dir.appendingPathComponent("far_sweep.tsv"), atomically: true, encoding: .utf8)
        for s in EchoFarSweep.best(far).prefix(10) { log("echo far: " + EchoFarSweep.line(s)) }
        if let release = far.first(where: { $0.settings == EchoDetection.FarSettings() }) { log("echo far: release " + EchoFarSweep.line(release)) }
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
                let all = (others + own + echoes).sorted { $0.start < $1.start }
                for e in EchoDetection.evidence(all, locale: locale, maxDelay: EchoDetection.Settings().maxDelay) {
                    if echoIDs.contains(e.id) { replay.echoes.append(e) } else if ownIDs.contains(e.id) { replay.own.append(e) }
                }
                // The others' lines that the participant's speakers echo must never be taken for the far side's echo.
                replay.othersOwn = EchoDetection.evidence(all, locale: locale, maxDelay: EchoDetection.FarSettings().maxDelay, judging: .others)
                replay.othersLines = others.count
                out.append(replay)
            }
            for (condition, delay) in farDelays.enumerated() {
                var rng = Generator(seed: seed ^ fnv(name) ^ fnv(speaker) &+ UInt64(100 + condition))
                let back = simulatedEchoes(of: own, avoiding: others, rate: farErrorRate, delay: delay, vocabulary: vocabulary, rng: &rng)
                    .map { EchoDetection.Line(id: $0.id, channel: .others, start: $0.start, end: $0.end, text: $0.text) }
                let words = Dictionary((own + back).map { ($0.id, $0.text.split(separator: " ").count) }, uniquingKeysWith: { a, _ in a })
                var replay = Replay(condition: condition, farSide: true, words: words, ownLines: own.count,
                                    ownWords: own.reduce(0) { $0 + (words[$1.id] ?? 0) })
                let ownIDs = Set(own.map(\.id)), backIDs = Set(back.map(\.id))
                let all = (others + back + own).sorted { $0.start < $1.start }
                replay.own = EchoDetection.evidence(all, locale: locale, maxDelay: EchoDetection.Settings().maxDelay).filter { ownIDs.contains($0.id) }
                for e in EchoDetection.evidence(all, locale: locale, maxDelay: EchoDetection.FarSettings().maxDelay, judging: .others) {
                    if backIDs.contains(e.id) { replay.backs.append(e) } else { replay.othersOwn.append(e) }
                }
                replay.backLines = back.count
                replay.backWords = back.reduce(0) { $0 + (words[$1.id] ?? 0) }
                replay.othersLines = others.count
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
            let start = group[0].start + delay + rng.spread(jitter)
            let end = max(start, group[group.count - 1].end + delay + rng.spread(jitter))
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
                        // No limit: what the far side's echo marks without it.
                        for maxLead in [0.1, 0.15, 0.2, 0.3, .infinity] {
                            var s = EchoDetection.Settings()
                            (s.words, s.pairs, s.covered, s.minWords, s.maxLead) = (words, pairs, covered, minWords, maxLead)
                            scores.append(score(s, replays))
                        }
                    }
                }
            }
        }
        return scores
    }

    static func score(_ s: EchoDetection.Settings, _ replays: [Replay]) -> Score {
        var found = Array(repeating: 0, count: conditions.count), total = Array(repeating: 0, count: conditions.count)
        var ownMarked = 0, ownLines = 0, wordsFound = 0, echoWords = 0, ownWordsMarked = 0, ownWords = 0, farMarked = 0, farLines = 0
        for r in replays {
            if r.farSide {
                farMarked += r.own.filter { $0.isEcho(s) }.count
                farLines += r.ownLines
                continue
            }
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
                     recallByCondition: zip(found, total).map { rate($0, $1) }, farMarked: farMarked, farLines: farLines)
    }

    /// The settings that mark at most `maxOwnMarked` of the own lines, most echo words found first (fewer own lines marked, with
    /// and without the far side's echo, on a tie).
    static func best(_ scores: [Score]) -> [Score] {
        scores.filter { $0.ownMarkedRate <= maxOwnMarked }
            .sorted { a, b in
                a.wordRecall == b.wordRecall ? a.ownMarked + a.farMarked < b.ownMarked + b.farMarked : a.wordRecall > b.wordRecall
            }
    }

    private static func line(_ s: Score) -> String {
        String(format: "words %.1f pairs %.1f covered %.1f min %d lead %.2f: recall %.3f (words %.3f), own marked %d of %d (%.2f %%, words %.2f %%), with the far side's echo %d of %d (%.2f %%)",
               s.settings.words, s.settings.pairs, s.settings.covered, s.settings.minWords, s.settings.maxLead, s.recall, s.wordRecall, s.ownMarked,
               s.ownLines, s.ownMarkedRate * 100, s.ownWordsMarked * 100, s.farMarked, s.farLines, s.farMarkedRate * 100)
    }

    private static func table(_ scores: [Score]) -> String {
        let byCondition = conditions.map { String(format: "recall_err%02.0f_delay%03.0f", $0.rate * 100, $0.delay * 1000) }
        var rows = [(["words", "pairs", "covered", "min_words", "max_lead", "recall", "word_recall", "own_marked", "own_lines", "own_marked_rate",
                      "own_words_marked_rate", "far_marked", "far_lines", "far_marked_rate"] + byCondition).joined(separator: "\t")]
        for s in scores {
            rows.append(([String(s.settings.words), String(s.settings.pairs), String(s.settings.covered), String(s.settings.minWords),
                          String(s.settings.maxLead), String(format: "%.4f", s.recall), String(format: "%.4f", s.wordRecall), String(s.ownMarked),
                          String(s.ownLines), String(format: "%.5f", s.ownMarkedRate), String(format: "%.5f", s.ownWordsMarked), String(s.farMarked),
                          String(s.farLines), String(format: "%.5f", s.farMarkedRate)]
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
        /// In [-x, x).
        mutating func spread(_ x: Double) -> Double { (unit() * 2 - 1) * x }
        mutating func index(_ count: Int) -> Int { Int(next() % UInt64(count)) }
    }
}
