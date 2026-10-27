// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// Progress of the integrated model reading a meeting: "Reading the transcript · 42%". Apple's model and the servers report nothing
/// of the kind and keep the indeterminate line.
extension LLMService {
    /// A function the model calls as it reads the prompt (at most four times a second). `minimumRead`: tokens that have to be read
    /// (not counting what a kept prefix already held) before anything is shown, so a question that costs a second does not flash a bar.
    nonisolated func prefillReporter(minimumRead: Int = 0) -> @Sendable (Int, Int) -> Void {
        struct State { var base: Int?; var lastEmit = Date.distantPast; var sequence = 0 }
        let state = Mutex(State())
        let reader = Self.nextReader.withLock { $0 += 1; return $0 }
        return { [weak self] done, total in
            // Each report is delivered by a task of its own: the order of the calls is numbered here, so a late one can be told.
            let sequence: Int? = state.withLock { s in
                if s.base == nil { s.base = done }
                guard total - (s.base ?? 0) >= minimumRead else { return nil }
                let now = Date()
                guard done >= total || now.timeIntervalSince(s.lastEmit) >= 0.25 else { return nil }
                s.lastEmit = now
                s.sequence += 1
                return s.sequence
            }
            guard let sequence else { return }
            Task { await self?.progressPrefill(done: done, total: total, reader: reader, sequence: sequence) }
        }
    }

    private static let nextReader = Mutex(0)

    func progressPrefill(done: Int, total: Int, reader: Int = 0, sequence: Int = 0) {
        guard status.activity != nil else { return }
        // A report older than one already applied (or from an earlier reading) changes nothing, also after the reading finished.
        if reader > 0 {
            if let last = lastPrefillReport, reader < last.reader || (reader == last.reader && sequence <= last.sequence) { return }
            lastPrefillReport = (reader, sequence)
        }
        if done >= total {
            status.prefill = nil
            if status.stage == .readingTranscript { status.stage = .writingMinutes }
        } else {
            // A report that arrives late (the reports are delivered by tasks of their own) never moves the bar back.
            if let current = status.prefill, current.total == total, done < current.done { return }
            status.stage = .readingTranscript
            status.prefill = PrefillProgress(done: done, total: total)
        }
        publish()
    }

    func setStage(_ stage: Stage?) {
        guard status.stage != stage else { return }
        status.stage = stage
        if stage != .readingTranscript { status.prefill = nil }
        publish()
    }

    func clearProgress() {
        status.stage = nil
        status.prefill = nil
    }
}
