// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// `llm-eval --tasks echo`, the far side's echo (`EchoDetection.farEchoes`): over the same replays as the speakers' echo, the share of
/// the participant's lines sent back into Others that are found, and the share of the other participants' own lines marked, in the
/// replays without the far side's echo (where the participant's speakers echo them instead) and with it. Writes `echo/far_sweep.tsv`.
enum EchoFarSweep {
    struct Score: Equatable {
        let settings: EchoDetection.FarSettings
        let recall: Double
        let wordRecall: Double
        /// The others' own lines marked in the replays with the speakers' echo, and their number.
        let othersMarked: Int
        let othersLines: Int
        /// The same in the replays with the far side's echo.
        let othersMarkedFar: Int
        let othersLinesFar: Int
        var othersMarkedRate: Double { othersLines == 0 ? 0 : Double(othersMarked) / Double(othersLines) }
        var othersMarkedFarRate: Double { othersLinesFar == 0 ? 0 : Double(othersMarkedFar) / Double(othersLinesFar) }
    }

    static func sweep(_ replays: [EchoEvaluation.Replay]) -> [Score] {
        var scores: [Score] = []
        for words in [0.5, 0.6, 0.7] {
            for pairs in [0.2, 0.3, 0.4] {
                for covered in [0.5, 0.6, 0.8] {
                    for minWords in [3, 4, 5] {
                        for minLag in [0.05, 0.1, 0.15, 0.2] {
                            var s = EchoDetection.FarSettings()
                            (s.words, s.pairs, s.covered, s.minWords, s.minLag) = (words, pairs, covered, minWords, minLag)
                            scores.append(score(s, replays))
                        }
                    }
                }
            }
        }
        return scores
    }

    static func score(_ s: EchoDetection.FarSettings, _ replays: [EchoEvaluation.Replay]) -> Score {
        var found = 0, lines = 0, wordsFound = 0, words = 0, marked = 0, others = 0, markedFar = 0, othersFar = 0
        for r in replays {
            let markedHere = r.othersOwn.filter { s.admits($0) }.count
            if r.farSide {
                let hits = r.backs.filter { s.admits($0) }
                found += hits.count
                lines += r.backLines
                wordsFound += hits.reduce(0) { $0 + (r.words[$1.id] ?? 0) }
                words += r.backWords
                markedFar += markedHere
                othersFar += r.othersLines
            } else {
                marked += markedHere
                others += r.othersLines
            }
        }
        func rate(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
        return Score(settings: s, recall: rate(found, lines), wordRecall: rate(wordsFound, words), othersMarked: marked, othersLines: others,
                     othersMarkedFar: markedFar, othersLinesFar: othersFar)
    }

    /// The settings that mark at most `EchoEvaluation.maxOwnMarked` of the others' own lines (with and without the far side's echo),
    /// most echo words found first.
    static func best(_ scores: [Score]) -> [Score] {
        scores.filter { $0.othersMarkedRate <= EchoEvaluation.maxOwnMarked && $0.othersMarkedFarRate <= EchoEvaluation.maxOwnMarked }
            .sorted { a, b in
                a.wordRecall == b.wordRecall ? a.othersMarked + a.othersMarkedFar < b.othersMarked + b.othersMarkedFar : a.wordRecall > b.wordRecall
            }
    }

    static func line(_ s: Score) -> String {
        String(format: "words %.1f pairs %.1f covered %.1f min %d lag %.2f: recall %.3f (words %.3f), others marked %d of %d (%.2f %%), with the far side's echo %d of %d (%.2f %%)",
               s.settings.words, s.settings.pairs, s.settings.covered, s.settings.minWords, s.settings.minLag, s.recall, s.wordRecall,
               s.othersMarked, s.othersLines, s.othersMarkedRate * 100, s.othersMarkedFar, s.othersLinesFar, s.othersMarkedFarRate * 100)
    }

    static func table(_ scores: [Score]) -> String {
        var rows = [["words", "pairs", "covered", "min_words", "min_lag", "recall", "word_recall", "others_marked", "others_lines",
                     "others_marked_rate", "others_marked_far", "others_lines_far", "others_marked_far_rate"].joined(separator: "\t")]
        for s in scores {
            rows.append([String(s.settings.words), String(s.settings.pairs), String(s.settings.covered), String(s.settings.minWords),
                         String(s.settings.minLag), String(format: "%.4f", s.recall), String(format: "%.4f", s.wordRecall), String(s.othersMarked),
                         String(s.othersLines), String(format: "%.5f", s.othersMarkedRate), String(s.othersMarkedFar), String(s.othersLinesFar),
                         String(format: "%.5f", s.othersMarkedFarRate)].joined(separator: "\t"))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
