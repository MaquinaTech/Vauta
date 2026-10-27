// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The end of speaker separation for one meeting: cluster every window embedding, align the speakers with the
/// transcript, write them, and delete the embeddings.
///
/// ORDER (it matters, and the callers enforce it):
///
/// 1. the segments are final (everything the recognizer produced is in the store);
/// 2. `SpeakerFinalizer.finalize` splits segments at speaker changes and assigns speakers;
/// 3. only then are translations refined (a split cuts the stored translation of the segment in proportion; a
///    late translation of the whole text no longer matches a split segment and is dropped, never misplaced),
///    the meeting analyzed (mentions point at segments) and its minutes written.
///
/// `LLMService.meetingEnded` calls `finalizePending` first, so a meeting whose speakers were not finalized yet (a
/// crashed recording) is finalized before its minutes in every path. If that last try fails, the meeting keeps its
/// transcript unsplit and the embeddings are deleted.
public enum SpeakerFinalizer {
    public enum Outcome: Equatable, Sendable {
        /// Speakers were written: the number of Others speakers.
        case written(Int)
        /// Nothing to write: speakers are off for this meeting, nothing was analysed, or nobody spoke.
        case skipped
        /// Clustering or the write failed. The window embeddings are kept, so the next launch tries again.
        case failed
    }

    /// Finalizes a meeting that has just stopped recording (or an import). `run` has the windows of this process; when
    /// nil they are read from the store, where a crashed recording left them. The embeddings are deleted when the
    /// speakers are written or there is nothing to write, and kept when the write fails.
    @discardableResult
    public static func finalize(meetingID: Int64, in store: MeetingStore, run: DiarizationRun? = nil,
                                wordRuns: [Int64: [AlignableSegment.Run]] = [:], recognizeVoices: Bool = false,
                                config: DiarizationConfig = DiarizationConfig()) async -> Outcome {
        do {
            if try await store.speakersOff(meetingID: meetingID) {
                try await store.deleteDiarizationWindows(meetingID: meetingID)
                return .skipped
            }
            let source: DiarizationRun
            if let run, !run.records.isEmpty {
                source = run
            } else {
                let records = try await store.diarizationWindows(meetingID: meetingID)
                source = DiarizationRun(records: records, totalSamples: (records.last?.startSample ?? 0) + SegmentationGeometry.windowSamples)
            }
            guard !source.records.isEmpty else {
                try await store.deleteDiarizationWindows(meetingID: meetingID)
                return .skipped
            }
            // The clustering is the slow part (about 0.07 s for an hour of speech, measured); keep it off the store's actor.
            let diarization = await Task.detached(priority: .userInitiated) {
                Reconstruction.diarize(records: source.records, totalSamples: source.totalSamples, config: config)
            }.value
            let written = try await store.applyDiarization(diarization, to: meetingID, wordRuns: wordRuns, recognizeVoices: recognizeVoices)
            try await store.deleteDiarizationWindows(meetingID: meetingID)
            return written > 0 ? .written(written) : .skipped
        } catch {
            return .failed
        }
    }

    /// Finalizes the meeting if its window embeddings are still in the store (its recording never reached the end).
    /// `enabled` is the global speaker separation setting now: when off, the embeddings are deleted unused. This is the
    /// last try for the meeting (its minutes follow), so a failure deletes the embeddings too, like `recoverInterrupted`.
    public static func finalizePending(meetingID: Int64, in store: MeetingStore, enabled: Bool = true, recognizeVoices: Bool = false,
                                       config: DiarizationConfig = DiarizationConfig()) async {
        guard (try? await store.hasDiarizationWindows(meetingID: meetingID)) == true else { return }
        let outcome: Outcome? = enabled ? await finalize(meetingID: meetingID, in: store, recognizeVoices: recognizeVoices, config: config) : nil
        if outcome == nil || outcome == .failed {
            try? await store.deleteDiarizationWindows(meetingID: meetingID)
        }
    }

    /// At launch: finalizes every meeting a crash left with window embeddings. Returns their IDs. This is the last
    /// try: voice data is not kept for a meeting whose speakers cannot be written, so a failure here deletes the
    /// embeddings too (the meeting stays without speakers, like one recorded with speakers off).
    ///
    /// `enabled` is the user's global speaker separation setting NOW: if it was turned off after the crash, the
    /// embeddings are deleted without writing speakers ("off" means meetings are stored exactly as before).
    @discardableResult
    public static func recoverInterrupted(in store: MeetingStore, enabled: Bool = true, recognizeVoices: Bool = false,
                                          config: DiarizationConfig = DiarizationConfig()) async -> [Int64] {
        let pending = (try? await store.meetingsWithDiarizationWindows()) ?? []
        for id in pending {
            if !enabled {
                try? await store.deleteDiarizationWindows(meetingID: id)
            } else if await finalize(meetingID: id, in: store, recognizeVoices: recognizeVoices, config: config) == .failed {
                try? await store.deleteDiarizationWindows(meetingID: id)
            }
        }
        return pending
    }
}
