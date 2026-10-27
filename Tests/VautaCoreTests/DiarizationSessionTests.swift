// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The window schedule: absolute sample placement, gaps, backlog skipping and the padded tail.
@Suite("Diarization session")
struct DiarizationSessionTests {
    private func session(_ analyzer: ScriptedAnalyzer = ScriptedAnalyzer(), catchUp: Int = 15) -> DiarizationSession {
        DiarizationSession(analyzer: analyzer, config: DiarizationConfig(), maxCatchUpWindows: catchUp)
    }

    private func audio(_ seconds: Double) -> [Float] { [Float](repeating: 0.1, count: Int(seconds * 16_000)) }

    @Test func aWindowIsDueWhenTenSecondsArrived() throws {
        let s = session()
        s.append(audio(9.9), at: 0)
        #expect(s.dueWindows == 0)
        s.append(audio(0.1), at: 158_400)
        #expect(s.dueWindows == 1)
        s.append(audio(2), at: 160_000)
        #expect(s.dueWindows == 2, "one more every 2 s")
        #expect(try s.processNext() == 0 && s.dueWindows == 1)
    }

    @Test func aRepeatedChunkChangesNothing() {
        let s = session()
        s.append(audio(11), at: 0)
        s.append(audio(1), at: 160_000)       // overlaps the end of what is there
        #expect(s.totalSamples == 176_000)
        s.append(audio(2), at: 100_000)       // entirely old
        #expect(s.totalSamples == 176_000)
    }

    @Test func aMissingStretchIsSilenceNotAShift() throws {
        let analyzer = ScriptedAnalyzer()
        analyzer.keepsWindows = true
        let s = session(analyzer)
        s.append(audio(4), at: 0)
        s.append(audio(8), at: 80_000)         // 1 s never arrived (64_000..<80_000)
        _ = try s.processNext()
        let window = analyzer.windows[0]
        #expect(window[63_999] == 0.1 && window[64_000] == 0 && window[79_999] == 0 && window[80_000] == 0.1)
        #expect(s.totalSamples == 208_000)
    }

    @Test func aLongGapRestartsTheBuffer() throws {
        let s = session()
        s.append(audio(5), at: 0)
        s.append(audio(12), at: 2_000_000)
        #expect(s.dueWindows >= 1)
        #expect(try s.processNext() != nil)
        #expect(s.records[0].startSample >= 2_000_000, "nothing is analysed from before the gap")
    }

    @Test func theOldestWindowsAreSkippedBeyondTheBacklog() throws {
        let s = session(catchUp: 3)
        s.append(audio(60), at: 0)
        #expect(s.dueWindows == 3)
        #expect(s.skippedWindows == 23, "26 windows were due, 3 are kept")
        _ = try s.processNext()
        #expect(s.records[0].startSample == 23 * 32_000, "the newest are kept")
    }

    @Test func theTailIsAnalysedWithSilencePadding() throws {
        let s = session()
        s.append(audio(23), at: 0)
        let run = try s.finish()
        #expect(run.totalSamples == 23 * 16_000)
        #expect(run.records.map(\.startSample) == (0...9).map { $0 * 32_000 }.filter { $0 <= 23 * 16_000 })
        #expect(run.records.last!.startSample + 96_000 >= run.totalSamples)
    }

    @Test func noAudioMeansNoWindows() throws {
        #expect(try session().finish().records.isEmpty)
        let s = session()
        s.append([], at: 0)
        #expect(try s.finish().totalSamples == 0)
    }

    @Test func aShortRecordingStillGetsOneWindow() throws {
        let s = session()
        s.append(audio(3), at: 0)
        let run = try s.finish()
        #expect(run.records.map(\.startSample) == [0])
    }
}
