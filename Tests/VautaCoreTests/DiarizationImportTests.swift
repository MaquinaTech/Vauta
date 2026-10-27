// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Imported recordings (and the `diarize` command) go through the same window pipeline as a live meeting, offline.
@Suite("Diarization: offline and import")
struct DiarizationImportTests {
    private func chunks(seconds: Int, size: Int = 1_600) -> () throws -> [Float]? {
        var sent = 0
        let total = seconds * 16_000
        return {
            guard sent < total else { return nil }
            defer { sent += size }
            return [Float](repeating: 0.1, count: min(size, total - sent))
        }
    }

    @Test func theOfflineRunSchedulesWindowsLikeALiveMeeting() throws {
        let analyzer = ScriptedAnalyzer(speakerAt: { $0 < 40 ? 0 : 1 })
        let run = try OfflineDiarization.run(chunks: chunks(seconds: 70), analyzer: analyzer)
        #expect(run.totalSamples == 70 * 16_000)
        #expect(run.skippedWindows == 0, "offline never skips: it reads as fast as it analyses")
        #expect(run.records.map(\.startSample).prefix(4) == [0, 32_000, 64_000, 96_000])
        #expect(run.records.last!.startSample + 96_000 >= run.totalSamples, "the tail is covered by a padded window")

        // a live session fed the same audio in one piece schedules the same windows
        let session = DiarizationSession(analyzer: ScriptedAnalyzer(speakerAt: { $0 < 40 ? 0 : 1 }), config: DiarizationConfig(), maxCatchUpWindows: 1_000)
        session.append([Float](repeating: 0.1, count: 70 * 16_000), at: 0)
        #expect(try session.finish().records.map(\.startSample) == run.records.map(\.startSample))
    }

    @Test func oneHugeChunkSkipsNoWindowAndNeedsNoLiveReclustering() throws {
        var sent = false
        let run = try OfflineDiarization.run(chunks: {
            defer { sent = true }
            return sent ? nil : [Float](repeating: 0.1, count: 300 * 16_000)
        }, analyzer: ScriptedAnalyzer())
        #expect(run.skippedWindows == 0, "150 windows are due at once; a live session would keep only 15")
        #expect(run.records.count >= 140)
    }

    @Test func aCancelledOfflineRunStops() async {
        let analyzer = ScriptedAnalyzer()
        let task = Task { () throws -> DiarizationRun in
            try OfflineDiarization.run(chunks: { Thread.sleep(forTimeInterval: 0.001); return [Float](repeating: 0, count: 1_600) }, analyzer: analyzer)
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func theRealModelsRunOverAClipThroughTheOfflinePipeline() throws {
        let clip = try DiarizationFixtures.clip()
        var offset = 0
        let analyzer = try WindowAnalyzer(models: DiarizationModels.verified())
        let run = try OfflineDiarization.run(chunks: {
            guard offset < clip.count else { return nil }
            defer { offset += 1_600 }
            return Array(clip[offset..<min(clip.count, offset + 1_600)])
        }, analyzer: analyzer)
        #expect(run.totalSamples == clip.count)
        #expect(run.records.map(\.startSample) == [0, 32_000, 64_000, 96_000])
        let diarization = Reconstruction.diarize(records: run.records, totalSamples: run.totalSamples)
        #expect(diarization.speakerCount >= 1 && !diarization.turns.isEmpty)
        #expect(diarization.turns.allSatisfy { $0.start >= 0 && $0.end <= Double(clip.count) / 16_000 + 0.5 })
        let rttm = Reconstruction.rttm(diarization.turns, fileID: "clip")
        #expect(rttm.hasPrefix("SPEAKER clip 1 "))
    }

    // MARK: Import

    private func importSegments() -> [Segment] {
        let text = "one two three four five six seven eight"
        let words = text.split(separator: " ").enumerated().map { index, word in
            let lower = text.distance(from: text.startIndex, to: word.startIndex)
            return AlignableSegment.Run(range: lower..<(lower + word.count), start: 84 + Double(index) * 1.5, end: 85.5 + Double(index) * 1.5)
        }
        return [Segment(channel: .others, start: 10, end: 14, text: "good morning team", isFinal: true),
                Segment(channel: .others, start: 84, end: 96, text: text, isFinal: true, words: words),
                Segment(channel: .others, start: 120, end: 124, text: "see you all", isFinal: true)]
    }

    private func diarization() -> Diarization {
        var random = TestRandom(seed: 1)
        let centres = (0..<2).map { _ in random.unitVector() }
        let records = SyntheticRecords.records(plan: (0..<90).map { [$0 < 45 ? 0 : 1] }, centres: centres, noise: 0.03)
        return Reconstruction.diarize(records: records, totalSamples: 90 * 32_000 + 160_000)
    }

    @Test func anImportedRecordingGetsItsSpeakersBeforeItIsAnalyzed() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let plan = RecordingImportPlan(fileName: "call.m4a", recordedAt: .now, duration: 130)
        let id = try await store.importMeeting(plan, segments: importSegments(), locale: Locale(identifier: "en-US"), diarization: diarization())
        let stored = try await store.segments(of: id)
        #expect(stored.count == 4, "the segment that spans the change is split in two, between words")
        #expect(stored.map(\.speaker?.ordinal) == [1, 1, 2, 2])
        #expect(stored.allSatisfy { $0.channel == .others })
        #expect(try await store.speakers(of: id).map(\.ordinal) == [1, 2])
        #expect(try await store.hasDiarizationWindows(meetingID: id) == false, "an import never stores window embeddings")
    }

    @Test func anImportWithoutDiarizationIsAsBefore() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let plan = RecordingImportPlan(fileName: "call.m4a", recordedAt: .now, duration: 130)
        let id = try await store.importMeeting(plan, segments: importSegments(), locale: Locale(identifier: "en-US"))
        let stored = try await store.segments(of: id)
        #expect(stored.map(\.text) == importSegments().map(\.text), "no splits, text untouched")
        #expect(stored.allSatisfy { $0.speaker == nil })
        #expect(try await store.speakers(of: id).isEmpty)
    }

    @Test func importKeepsWordTimesOfTheTranscript() {
        let segments = RecordingImportPlan.transcript(from: importSegments())
        #expect(segments.map(\.words.count) == [0, 8, 0])
    }
}
