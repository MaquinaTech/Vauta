// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Find in a meeting: where a text is in the transcript and the moves between the places.
@Suite("Find in a meeting")
struct TranscriptFindTests {
    static let lines: [(id: Int64, text: String)] = [
        (10, "We reviewed the presupuesto for Q3."),
        (11, "El presupuesto sube; PRESUPUESTO final el viernes."),
        (12, "Nothing about money here."),
        (13, "Ｑ３ is the quarter, and q3 again."),
    ]

    @Test func theTextIsFoundAsTypedAnywhereInAWord() {
        let found = TranscriptFind.matches(of: "presup", in: Self.lines)
        #expect(found.map(\.segment) == [10, 11, 11], "case ignored, every place in a line")
        let line = Self.lines[1].text
        #expect(TranscriptFind.ranges(of: 11, in: found).map { String(line[$0]) } == ["presup", "PRESUP"])
        #expect(TranscriptFind.matches(of: "q3", in: Self.lines).map(\.segment) == [10, 13, 13], "width ignored: full-width Ｑ３")
        #expect(TranscriptFind.matches(of: "the", in: Self.lines).map(\.segment) == [10, 13], "a function word too")
        #expect(TranscriptFind.matches(of: "  ", in: Self.lines).isEmpty && TranscriptFind.matches(of: "zzz", in: Self.lines).isEmpty)
        #expect(TranscriptFind.matches(of: "presupuesto", in: [(1, "Presupuésto y presupuesto")]).count == 2, "accents ignored")
        #expect(TranscriptFind.matches(of: "aa", in: [(1, "aaaa")]).count == 2, "places do not overlap")
    }

    @Test func movesWrapAroundAndStartWhereThePersonIs() {
        let found = TranscriptFind.matches(of: "presup", in: Self.lines)
        #expect(TranscriptFind.step(from: nil, forward: true, in: found) == 0)
        #expect(TranscriptFind.step(from: nil, forward: false, in: found) == 2)
        #expect(TranscriptFind.step(from: 2, forward: true, in: found) == 0, "after the last, the first")
        #expect(TranscriptFind.step(from: 0, forward: false, in: found) == 2, "before the first, the last")
        let order: [Int64] = [10, 11, 12, 13]
        #expect(TranscriptFind.step(from: nil, forward: true, in: found, from: 11, order: order) == 1, "from the highlighted passage on")
        #expect(TranscriptFind.step(from: nil, forward: false, in: found, from: 11, order: order) == 0, "back from it")
        #expect(TranscriptFind.step(from: nil, forward: true, in: found, from: 12, order: order) == 0, "none after it: from the top")
        #expect(TranscriptFind.step(from: nil, forward: true, in: []) == nil)
    }

    @Test func aTwoHourTranscriptIsSearchedWhileTyping() {
        // Two hours of a busy meeting: a line every 4 seconds, about 20 words each, the word in every line (the worst case:
        // about 40 ms in a debug build on an M2). The best of three runs, so a busy test machine does not fail it; a CI runner, a
        // virtual machine running the parallel suite with coverage, took 137 ms, so there the bound is half a second. A search that
        // grew with the square of the lines would take seconds.
        let words = "so the budget for the next quarter depends on what the client signs and on the hiring plan we agreed".split(separator: " ")
        let lines: [(id: Int64, text: String)] = (0..<1_800).map { i in (Int64(i), (0..<20).map { String(words[(i + $0) % words.count]) }.joined(separator: " ")) }
        let clock = ContinuousClock()
        var found: [TranscriptFind.Match] = []
        let elapsed = (0..<3).map { _ in clock.measure { found = TranscriptFind.matches(of: "budget", in: lines) } }.min()!
        #expect(found.count >= 1_800)
        #expect(elapsed < .milliseconds(TestMachine.isVirtual ? 500 : 100), "\(elapsed)")
    }
}
