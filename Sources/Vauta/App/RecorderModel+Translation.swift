// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore

/// Where the translations of a recording that has ended go, if the model server answers after the stop.
/// The segments' store rows are copied when the recording's writes are done, because the
/// recorder forgets them as soon as the next recording starts.
@MainActor
final class EndedTranslationTarget {
    let store: MeetingStore
    private(set) var meetingID: Int64?
    private(set) var rows: [Int: Int64] = [:]
    /// Finishes when `complete` has been called.
    let ready: Task<Void, Never>
    private let signal: AsyncStream<Void>.Continuation

    init(store: MeetingStore) {
        self.store = store
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        signal = continuation
        ready = Task { for await _ in stream {} }
    }

    func complete(meetingID: Int64?, rows: [Int: Int64]) {
        self.meetingID = meetingID
        self.rows = rows
        signal.finish()
    }
}

/// Live Translation: storing what the translator produces.
extension RecorderModel {
    /// Stores a final translation encrypted with the transcript. It joins the
    /// write chain behind the segment's own write, so the segment exists by
    /// then. A failure is silent: the transcript matters, the translation is a bonus.
    /// `recording` is the recording the translation belongs to: after the stop only the
    /// ended recording's own target is used, and only if its meeting still has that segment.
    func storeTranslation(_ final: FinalTranslation, recording: Int) {
        guard let store else { return }
        if recording != liveTranslation.recordingNumber || !(liveTranslation.isRecording || liveTranslation.isEnding) {
            storeLateTranslation(final, recording: recording)
            return
        }
        let previous = writes
        writes = Task {
            await previous?.value
            guard let row = segmentRowIDs[final.key] else { return }
            try? await store.saveTranslation(final.text, language: final.language, of: row,
                                             source: final.source.isEmpty ? nil : final.source)
        }
    }

    /// Registers where late answers of the recording that is ending go. Call before `recordingEnded()`.
    func beginEndedTranslationTarget() -> EndedTranslationTarget? {
        guard let store, liveTranslation.isRunning else { return nil }
        let target = EndedTranslationTarget(store: store)
        endedTranslationTargets[liveTranslation.recordingNumber] = target
        return target
    }

    private func storeLateTranslation(_ final: FinalTranslation, recording: Int) {
        guard let target = endedTranslationTargets[recording], !final.source.isEmpty else { return }
        Task {
            await target.ready.value
            guard let meetingID = target.meetingID, let row = target.rows[final.key] else { return }
            _ = try? await target.store.saveLateTranslation(final.text, language: final.language, of: row,
                                                            inMeeting: meetingID, source: final.source)
        }
    }
}
